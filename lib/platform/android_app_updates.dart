// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'app_updates.dart';

/// Networking and file verification stay in Dart; Android owns package trust
/// and installation UI. No download is started by an automatic version check.
class AndroidAppUpdateService extends AppUpdateService {
  AndroidAppUpdateService({
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _temporaryDirectory;

  static const _channel = MethodChannel(
    'tech.soit.flutterairplay/androidUpdates',
  );
  static final feed = Uri.parse(
    'https://github.com/boyan01/flutter-airplay/releases/latest/download/appcast.xml',
  );
  ValueChanged<Map<String, dynamic>>? _listener;
  HttpClient? _client;
  File? _apk;
  Map<String, dynamic>? _update;
  int _revision = 0, _generation = 0, _installedBuild = 0;
  bool _enabled = false;
  String _status = 'idle';
  String? _error, _reason;
  double? _progress;

  Map<String, dynamic> _snapshot() => {
    'revision': _revision,
    'enabled': _enabled,
    'reason': _reason,
    'status': _status,
    'version': _update?['version'],
    'releaseNotes': _update?['releaseNotes'],
    'error': _error,
    'progress': _progress,
    'capabilities': {
      'checkForUpdates': _status != 'downloading' && _status != 'ready',
      'showUpdate': _update != null,
      'installUpdate': _update != null && _status != 'downloading',
      'cancelUpdate': _status == 'downloading',
    },
  };

  void _emit() {
    _revision++;
    _listener?.call(_snapshot());
  }

  @override
  void listen(ValueChanged<Map<String, dynamic>>? listener) {
    _listener = listener;
    if (listener == null) {
      _generation++;
      _client?.close(force: true);
    }
  }

  @override
  Future<Map<String, dynamic>> initialize() async {
    final info = await PackageInfo.fromPlatform();
    _installedBuild = int.parse(info.buildNumber);
    _enabled = kReleaseMode;
    _reason = _enabled
        ? null
        : 'Updates require a release build signed with the release key.';
    if (_enabled) {
      final directory = Directory(
        '${(await _temporaryDirectory()).path}/updates',
      );
      if (await directory.exists()) {
        await for (final file in directory.list()) {
          if (file is File && file.path.endsWith('.apk')) await file.delete();
        }
      }
    }
    return _snapshot();
  }

  static void validateManifest(Map<String, dynamic> data) {
    final version = data['version'];
    final build = data['versionCode'];
    final size = data['size'];
    final hash = data['sha256'];
    final url = Uri.tryParse(
      data['url'] is String ? data['url'] as String : '',
    );
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build is! int ||
        build <= 0 ||
        size is! int ||
        size <= 0 ||
        size > 1024 * 1024 * 1024 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        data['releaseNotes'] is! String ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty) {
      throw const FormatException('Invalid Android update manifest.');
    }
  }

  static const androidNamespace =
      'https://github.com/boyan01/flutter-airplay/updates';

  static Map<String, dynamic>? parseAppcast(String source) {
    final document = XmlDocument.parse(source);
    final items = document.rootElement.name.local == 'rss'
        ? document.rootElement.getElement('channel')?.findElements('item')
        : null;
    if (items == null || items.length != 1) {
      throw const FormatException('Expected one appcast release.');
    }
    final item = items.single;
    final entries = item.findElements('android', namespace: androidNamespace);
    if (entries.isEmpty) return null;
    if (entries.length != 1) {
      throw const FormatException('Ambiguous Android update.');
    }
    final entry = entries.single;
    final data = <String, dynamic>{
      'version': entry.getAttribute('version'),
      'versionCode': int.tryParse(entry.getAttribute('versionCode') ?? ''),
      'size': int.tryParse(entry.getAttribute('length') ?? ''),
      'sha256': entry.getAttribute('sha256'),
      'url': entry.getAttribute('url'),
      // Sparkle embeds escaped HTML paragraphs. Parse text without rendering
      // HTML or fetching any external release-note content.
      'releaseNotes':
          XmlDocument.parse(
                '<notes>${item.getElement('description')?.innerText ?? ''}</notes>',
              ).rootElement.children
              .map((node) => node.innerText.trim())
              .where((text) => text.isNotEmpty)
              .join('\n'),
    };
    validateManifest(data);
    return data;
  }

  @override
  Future<Map<String, dynamic>> checkForUpdates() async {
    _error = null;
    _status = 'checking';
    _emit();
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    try {
      final request = await client
          .getUrl(feed)
          .timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == 404) {
        // Older releases have no Android feed.
        _update = null;
      } else {
        if (response.statusCode != 200) {
          throw HttpException(
            'Update check failed: HTTP ${response.statusCode}.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 256 * 1024) {
            throw const FormatException('Update manifest is too large.');
          }
        }
        final data = parseAppcast(utf8.decode(bytes));
        _update = data != null && (data['versionCode'] as int) > _installedBuild
            ? data
            : null;
      }
      _apk = null;
      _progress = null;
      _status = _update == null ? 'idle' : 'available';
    } catch (error) {
      _status = 'error';
      _error = error.toString();
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
    _emit();
    return _snapshot();
  }

  @override
  Future<Map<String, dynamic>> showUpdate() async => _snapshot();

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    if (_update == null || _status == 'downloading') return _snapshot();
    if (_apk != null) {
      // The system UI may be cancelled. Keep the verified download available
      // for another attempt, rather than claiming installation succeeded.
      _error = null;
      try {
        await _channel.invokeMethod<void>('install', {
          'path': _apk!.path,
          'versionCode': _update!['versionCode'],
        });
      } catch (error) {
        _error = error is PlatformException ? error.message : error.toString();
      }
      _emit();
      return _snapshot();
    }
    final generation = ++_generation;
    _status = 'downloading';
    _error = null;
    _progress = 0;
    _emit();
    // Return immediately so the shared controller can accept cancellation.
    unawaited(_download(generation, Map.of(_update!)));
    return _snapshot();
  }

  Future<void> _download(int generation, Map<String, dynamic> update) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    File? file;
    IOSink? sink;
    try {
      final directory = await _temporaryDirectory();
      if (generation != _generation) return;
      final updates = await Directory('${directory.path}/updates')
          .create(recursive: true);
      file = File('${updates.path}/update-$generation.apk');
      final request = await client
          .getUrl(Uri.parse(update['url'] as String))
          .timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'APK download failed: HTTP ${response.statusCode}.',
        );
      }
      sink = file.openWrite();
      var received = 0;
      final expected = update['size'] as int;
      var lastPercent = -1;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (generation != _generation) return;
        received += chunk.length;
        if (received > expected) {
          throw const FormatException('APK exceeds expected size.');
        }
        sink.add(chunk);
        await sink.flush();
        final percent = received * 100 ~/ expected;
        if (percent != lastPercent) {
          lastPercent = percent;
          _progress = received / expected;
          _emit();
        }
      }
      await sink.close();
      sink = null;
      if (received != expected) {
        throw const FormatException('APK download is incomplete.');
      }
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != update['sha256']) {
        throw const FormatException('APK checksum mismatch.');
      }
      if (generation != _generation) return;
      _apk = file;
      _status = 'ready';
      _progress = 1;
    } catch (error) {
      if (generation == _generation) {
        _status = 'error';
        _error = error is PlatformException ? error.message : error.toString();
      }
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
      try {
        await sink?.close();
        if (file != null && file != _apk && await file.exists()) {
          await file.delete();
        }
      } catch (error) {
        if (generation == _generation) {
          _status = 'error';
          _error ??= error.toString();
        }
      }
      if (generation == _generation) _emit();
    }
  }

  @override
  Future<Map<String, dynamic>> cancelUpdate() async {
    _generation++;
    _client?.close(force: true);
    _client = null;
    _status = _update == null ? 'idle' : 'available';
    _progress = null;
    _error = null;
    _emit();
    return _snapshot();
  }
}
