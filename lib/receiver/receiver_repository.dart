// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

abstract class ReceiverRepository {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> snapshot();
  Future<void> save(String name, String path);
  Future<void> start(String name, String path);
  Future<void> stop();
  Future<void> check(String path);
}

class NativeReceiverRepository implements ReceiverRepository {
  static const _control = MethodChannel('org.airplayreceiver/control');
  static const _events = EventChannel('org.airplayreceiver/events');

  @override
  Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  @override
  Future<Map<String, dynamic>> snapshot() async => Map<String, dynamic>.from(
    (await _control.invokeMapMethod<String, dynamic>('snapshot'))!,
  );

  Map<String, String> _settings(String name, String path) => {
    'name': name,
    'path': path,
  };

  @override
  Future<void> save(String name, String path) =>
      _control.invokeMethod('save', _settings(name, path));
  @override
  Future<void> start(String name, String path) =>
      _control.invokeMethod('start', _settings(name, path));
  @override
  Future<void> stop() => _control.invokeMethod('stop');
  @override
  Future<void> check(String path) =>
      _control.invokeMethod('check', {'path': path});
}
