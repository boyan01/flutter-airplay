// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'generated/receiver_bindings.dart';
import 'receiver_codec.dart';

/// Shared native commands and copied events, independent of Flutter channels.
abstract interface class ReceiverControl {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]);
  void dispose();
}

class FfiReceiverControl implements ReceiverControl {
  FfiReceiverControl(int handle, {DynamicLibrary? library}) : _handle = handle {
    try {
      _bindings = ReceiverBindings(library ?? _library());
      if (_bindings.airplay_receiver_abi_version() != 3) {
        throw StateError('Unsupported native receiver ABI');
      }
      _port.listen(_receive);
      _subscription = _bindings.airplay_receiver_attach(
        _handle,
        _port.sendPort.nativePort,
        NativeApi.postCObject.cast(),
      );
      if (_subscription == 0) {
        _port.close();
        throw StateError('Native receiver is unavailable');
      }
    } catch (_) {
      _port.close();
      unawaited(_events.close());
      rethrow;
    }
  }
  static DynamicLibrary _library() {
    if (Platform.isAndroid) return DynamicLibrary.open('libairplay_player.so');
    if (Platform.isWindows) return DynamicLibrary.open('airplay_player.dll');
    return DynamicLibrary.process();
  }

  final int _handle;
  final _port = ReceivePort();
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final ReceiverBindings _bindings;
  late final int _subscription;
  int _nextRequest = 0;
  bool _disposed = false;
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  void _receive(dynamic message) {
    if (_disposed) return;
    try {
      final event = Map<String, dynamic>.from(
        jsonDecode(message as String) as Map,
      );
      if (event['type'] != 'complete') {
        _events.add(event);
        return;
      }
      final reply = ReceiverReply.fromJson(event);
      final pending = _pending.remove(reply.request);
      if (pending == null) return;
      if (reply.error != null) {
        pending.completeError(
          PlatformException(code: 'receiver_error', message: reply.error),
        );
      } else {
        pending.complete(reply.data);
      }
    } catch (error, stack) {
      _events.addError(error, stack);
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) {
    if (_disposed) {
      return Future.error(StateError('Receiver control has closed'));
    }
    final request = ++_nextRequest;
    final completion = Completer<Map<String, dynamic>>();
    _pending[request] = completion;
    try {
      final bytes = jsonEncode({'method': method, 'arguments': arguments});
      final accepted = using(
        (arena) => _bindings.airplay_receiver_control(
          _handle,
          _subscription,
          request,
          bytes.toNativeUtf8(allocator: arena).cast(),
          utf8.encode(bytes).length,
        ),
      );
      if (!accepted) throw StateError('Native receiver has closed');
    } catch (error, stack) {
      _pending.remove(request);
      completion.completeError(error, stack);
    }
    return completion.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.airplay_receiver_detach(_handle, _subscription);
    _port.close();
    for (final completion in _pending.values) {
      completion.completeError(StateError('Receiver control has closed'));
    }
    _pending.clear();
    unawaited(_events.close());
  }
}
