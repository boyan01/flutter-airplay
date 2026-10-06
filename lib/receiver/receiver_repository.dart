// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'native/receiver_control.dart';
import 'receiver_settings_store.dart';
import 'receiver_state.dart';
import 'native/receiver_codec.dart';
export 'receiver_state.dart';

abstract class ReceiverRepository {
  Stream<ReceiverEvent> get events;
  Future<ReceiverState> snapshot();
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    bool? showPlaybackStats,
    Map<String, bool> desktopOptions = const {},
  });
  Future<void> start(String name, String path);
  // The native worker reserves an idle receiver atomically before restarting.
  Future<bool> applySettings();
  Future<void> stop();
  Future<void> disconnect() async {
    await stop();
    final state = await snapshot();
    await start(state.settings.name, state.settings.path);
  }

  Future<void> check(String path);
  void dispose() {}
}

class NativeReceiverRepository implements ReceiverRepository {
  NativeReceiverRepository({
    Future<Map<String, dynamic>> Function()? bootstrap,
    ReceiverControl Function(int handle)? connect,
    ReceiverSettingsStore? settings,
  }) : _bootstrap = bootstrap ?? _bootstrapHost,
       _connect = connect ?? FfiReceiverControl.new,
       _store = settings ?? ReceiverSettingsStore();

  static const _platform = MethodChannel('org.airplayreceiver/platform');
  static Future<Map<String, dynamic>> _bootstrapHost() async =>
      Map<String, dynamic>.from(
        (await _platform.invokeMapMethod<String, dynamic>('bootstrap'))!,
      );
  final Future<Map<String, dynamic>> Function() _bootstrap;
  final ReceiverControl Function(int handle) _connect;
  final _events = StreamController<ReceiverEvent>.broadcast();
  Future<void>? _initializing;
  Future<void> _saving = Future.value();
  ReceiverControl? _control;
  final ReceiverSettingsStore _store;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  ReceiverSettings _settings = const ReceiverSettings();
  String _hostPlatform = '', _buildVersion = '';
  bool _ready = false, _disposed = false, _applyQueued = false;

  Future<void> _initialize() =>
      _initializing ??= _open().catchError((Object error, StackTrace stack) {
        _initializing = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _open() async {
    final host = await _bootstrap();
    if (_disposed) throw StateError('Receiver repository has closed');
    final control = _connect(host['handle'] as int);
    _control = control;
    try {
      _subscription = control.events.listen(
        _event,
        onError: (Object error, StackTrace stack) {
          if (!_disposed) _events.addError(error, stack);
        },
      );
      final snapshot = decodeReceiverState(await control.request('snapshot'));
      _hostPlatform = snapshot.capabilities.platform;
      final saved = await _store.read();
      if (saved != null) await control.request('save', saved.toJson());
      _settings = (decodeReceiverState(await control.request('snapshot')))
          .settings;
      final info = await PackageInfo.fromPlatform();
      _buildVersion = '${info.version} (${info.buildNumber})';
      _ready = true;
      _scheduleSettingsApply();
    } catch (_) {
      await _subscription?.cancel();
      control.dispose();
      _control = null;
      rethrow;
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_disposed) return;
    if (event['type'] == 'startRequest') {
      unawaited(
        start(_settings.name, _settings.path).catchError((
          Object error,
          StackTrace stack,
        ) {
          if (!_disposed) _events.addError(error, stack);
        }),
      );
    } else if (event['type'] == 'settingsRequest') {
      final patch = Map<String, dynamic>.from(event['settings'] as Map);
      unawaited(
        _save(patch).catchError((Object error, StackTrace stack) {
          if (!_disposed) _events.addError(error, stack);
        }),
      );
    } else if (_ready) {
      if (event['type'] == 'snapshot') {
        final data = Map<String, dynamic>.from(event['data'] as Map);
        data['buildVersion'] = _buildVersion;
        _events.add(decodeReceiverEvent({...event, 'data': data}));
        _scheduleSettingsApply();
      } else {
        _events.add(decodeReceiverEvent(event));
      }
    }
  }

  @override
  Stream<ReceiverEvent> get events => _events.stream;
  @override
  Future<ReceiverState> snapshot() async {
    await _initialize();
    final state = decodeReceiverState(await _control!.request('snapshot'));
    return state.copyWith(buildVersion: _buildVersion);
  }

  @override
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    bool? showPlaybackStats,
    Map<String, bool> desktopOptions = const {},
  }) => _save({
    'name': name,
    'path': path,
    'autoStart': autoStart,
    'videoQuality': ?videoQuality,
    'audioOutput': ?audioOutput,
    'fastPairing': ?fastPairing,
    'showPlaybackStats': ?showPlaybackStats,
    ...desktopOptions,
  });
  Future<void> _save(Map<String, dynamic> patch) {
    final result = _saving.then((_) async {
      await _initialize();
      final before = _settings;
      final next = validatedReceiverSettings({...before.toJson(), ...patch});
      await _store.write(next);
      try {
        await _control!.request('save', next.toJson());
      } catch (_) {
        await _store.write(before);
        rethrow;
      }
      _settings = next;
      _scheduleSettingsApply();
    });
    _saving = result.catchError((Object _) {});
    return result;
  }

  void _scheduleSettingsApply() {
    if (_disposed || !_ready || _applyQueued) return;
    _applyQueued = true;
    unawaited(
      _saving
          .then((_) async {
            if (_disposed) return;
            final state = await snapshot();
            final active = state.activeSettings;
            if (state.status != ReceiverStatus.waiting ||
                active == null ||
                active.matchesRuntime(
                  _settings,
                  videoQualitySupported: state.videoQualities.isNotEmpty,
                  androidAudio: _hostPlatform == 'android',
                )) {
              return;
            }
            await _control!.request('applySettings');
          })
          .catchError((Object error, StackTrace stack) {
            if (!_disposed) _events.addError(error, stack);
          })
          .whenComplete(() {
            _applyQueued = false;
          }),
    );
  }

  Future<void> _prepare() async {
    if (_hostPlatform == 'android') {
      await _platform.invokeMethod('prepareReception');
    }
  }

  @override
  Future<void> start(String name, String path) async {
    await _save({'name': name, 'path': path});
    final before = decodeReceiverState(await _control!.request('snapshot'));
    await _prepare();
    await _control!.request('start', {'generation': before.generation});
  }

  @override
  Future<void> stop() async {
    await _initialize();
    await _control!.request('stop');
  }

  @override
  Future<void> disconnect() async {
    await _initialize();
    await _saving;
    await _control!.request('disconnect');
  }

  @override
  Future<bool> applySettings() async {
    await _initialize();
    await _saving;
    return (await _control!.request('applySettings'))['applied'] as bool;
  }

  @override
  Future<void> check(String path) async {
    await _initialize();
    await _control!.request('check', {'path': path});
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _control?.dispose();
    unawaited(_events.close());
  }
}
