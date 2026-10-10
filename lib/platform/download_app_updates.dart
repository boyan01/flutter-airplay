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

/// Shared feed/download lifecycle; each host owns installation and trust policy.
/// Automatic checks never start a download.
class DownloadAppUpdateService extends AppUpdateService {
  DownloadAppUpdateService({
    required this.platform,
    required this.extension,
    required this.installer,
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _temporaryDirectory;

  final String platform, extension;
  final MethodChannel installer;

  Map<String, dynamic>? parseManifest(String source) =>
      parseAppcast(source, platform: platform);

  Future<void> verifyManifest(Map<String, dynamic> data) async {}

  Future<bool> canEnable() async => kReleaseMode;
  static final feed = Uri.parse(
    'https://github.com/boyan01/flutter-airplay/releases/latest/download/appcast.xml',
  );
  ValueChanged<Map<String, dynamic>>? _listener;
  HttpClient? _client;
  File? _downloaded;
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
      'checkForUpdates': !{
        'downloading',
        'ready',
        'installing',
      }.contains(_status),
      'showUpdate': _update != null,
      'installUpdate':
          _update != null && !{'downloading', 'installing'}.contains(_status),
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
    _enabled = await canEnable();
    _reason = _enabled ? null : 'Updates require a configured release build and a supported installation.';
    if (_enabled) {
      final directory = Directory(
        '${(await _temporaryDirectory()).path}/updates',
      );
      if (await directory.exists()) {
        await for (final file in directory.list()) {
          if (file is File && file.path.endsWith('.$extension')) {
            await file.delete();
          }
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
      throw const FormatException('Invalid update manifest.');
    }
  }

  static const namespace = 'https://github.com/boyan01/flutter-airplay/updates';

  static Map<String, dynamic>? parseAppcast(
    String source, {
    String platform = 'android',
  }) {
    final document = XmlDocument.parse(source);
    final items = document.rootElement.name.local == 'rss'
        ? document.rootElement.getElement('channel')?.findElements('item')
        : null;
    if (items == null || items.length != 1) {
      throw const FormatException('Expected one appcast release.');
    }
    final item = items.single;
    final entries = item.findElements(platform, namespace: namespace);
    if (entries.isEmpty) return null;
    if (entries.length != 1) {
      throw const FormatException('Ambiguous update.');
    }
    final entry = entries.single;
    final data = <String, dynamic>{
      'version': entry.getAttribute('version'),
      'versionCode': int.tryParse(
        entry.getAttribute(platform == 'android' ? 'versionCode' : 'build') ??
            '',
      ),
      'size': int.tryParse(entry.getAttribute('length') ?? ''),
      'sha256': entry.getAttribute('sha256'),
      'url': entry.getAttribute('url'),
      if (platform == 'windows') ...{
        'arch': entry.getAttribute('arch'),
        'edSignature': entry.getAttribute('edSignature'),
      },
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
        final data = parseManifest(utf8.decode(bytes));
        if (data != null) await verifyManifest(data);
        _update = data != null && (data['versionCode'] as int) > _installedBuild
            ? data
            : null;
      }
      _downloaded = null;
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
    if (_update == null || {'downloading', 'installing'}.contains(_status)) {
      return _snapshot();
    }
    if (_downloaded != null) {
      // The system UI may be cancelled. Keep the verified download available
      // for another attempt, rather than claiming installation succeeded.
      _error = null;
      try {
        await installer.invokeMethod<void>('install', {
          'path': _downloaded!.path,
          'versionCode': _update!['versionCode'],
          if (platform == 'windows') 'sha256': _update!['sha256'],
        });
        if (platform == 'windows') _status = 'installing';
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
      file = File('${updates.path}/update-$generation.$extension');
      final request = await client
          .getUrl(Uri.parse(update['url'] as String))
          .timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'Update download failed: HTTP ${response.statusCode}.',
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
          throw const FormatException('Update exceeds expected size.');
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
        throw const FormatException('Update download is incomplete.');
      }
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != update['sha256']) {
        throw const FormatException('Update checksum mismatch.');
      }
      if (generation != _generation) return;
      _downloaded = file;
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
        if (file != null && file != _downloaded && await file.exists()) {
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
