// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

abstract class ReceiverRepository {
  Stream<Map<String, dynamic>> get events;
  // defaultName is the platform reset target. activeSettings contains the
  // settings captured at receiver startup, using the same keys as save. Future
  // receiver-run options must join this map and ReceiverModel._receiverSettings.
  Future<Map<String, dynamic>> snapshot();
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    Map<String, bool> desktopOptions = const {},
  });
  Future<void> start(String name, String path);
  // Hosts recheck session state before restarting. False means a connection or
  // lifecycle transition prevented the update; retry on the next idle event.
  Future<bool> applySettings();
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
  Future<Map<String, dynamic>> snapshot() async {
    final data = Map<String, dynamic>.from(
      (await _control.invokeMapMethod<String, dynamic>('snapshot'))!,
    );
    final info = await PackageInfo.fromPlatform();
    data['buildVersion'] = '${info.version} (${info.buildNumber})';
    return data;
  }

  Map<String, String> _settings(String name, String path) => {
    'name': name,
    'path': path,
  };

  @override
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    Map<String, bool> desktopOptions = const {},
  }) => _control.invokeMethod('save', {
    ..._settings(name, path),
    'autoStart': autoStart,
    'videoQuality': ?videoQuality,
    'audioOutput': ?audioOutput,
    'fastPairing': ?fastPairing,
    ...desktopOptions,
  });
  @override
  Future<void> start(String name, String path) =>
      _control.invokeMethod('start', _settings(name, path));
  @override
  Future<void> stop() => _control.invokeMethod('stop');
  @override
  Future<bool> applySettings() async =>
      await _control.invokeMethod<bool>('applySettings') ?? false;
  @override
  Future<void> check(String path) =>
      _control.invokeMethod('check', {'path': path});
}
