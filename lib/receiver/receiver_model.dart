// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

import 'receiver_repository.dart';

class ReceiverModel extends ChangeNotifier {
  ReceiverModel(this.repository);
  final ReceiverRepository repository;
  StreamSubscription<ReceiverEvent>? _subscription;
  final _logs = <ReceiverLog>[];
  int _lastWrittenLogID = 0;
  String status = 'stopped';
  String message = 'off';
  String name = 'Flutter AirPlay';
  String defaultName = 'Flutter AirPlay';
  ReceiverSettings? _activeSettings;
  // Add future receiver-run settings here. Immediate application/window
  // preferences do not require a receiver restart.
  ReceiverSettings get _receiverSettings => ReceiverSettings(
    name: name,
    path: path,
    fastPairing: fastPairing,
    videoQuality: VideoQuality.values.firstWhere(
      (value) => value.value == videoQuality,
    ),
    audioOutput: AudioOutput.values.byName(audioOutput),
  );
  bool get settingsPending =>
      active &&
      _activeSettings != null &&
      !_activeSettings!.matchesRuntime(
        _receiverSettings,
        videoQualitySupported: supportsVideoQuality,
        androidAudio: platform == 'android',
      );
  String? _receivingName;
  String get receivingName => active ? _receivingName ?? name : name;
  String path = '';
  bool autoStart = true;
  bool fastPairing = true;
  bool showPlaybackStats = false;
  PlaybackStats? playbackStats;
  String videoQuality = 'auto';
  String audioOutput = 'auto';
  String buildTime = '', buildVersion = '';
  List<String> videoQualities = const [];
  int screenWidth = 0, screenHeight = 0;
  bool get supportsVideoQuality => videoQualities.isNotEmpty;
  String? clientName;
  bool supportsLaunchAtLogin = false;
  final desktopOptions = <String, bool>{
    'launchAtLogin': false,
    'keepInMenuBar': true,
    'showOnConnect': true,
    'fullscreenOnConnect': false,
    'alwaysOnTop': false,
  };
  int textureId = -1, videoWidth = 0, videoHeight = 0;
  bool audioPlaying = false, videoPaused = false;
  bool get usesNativeVideo => platform == 'android';
  bool get hasVideo =>
      (usesNativeVideo || textureId >= 0) && videoWidth > 0 && videoHeight > 0;
  bool get showAudioPage =>
      status == 'streaming' && !hasVideo && (audioPlaying || videoPaused);

  String get platform => _platform;
  String _platform = defaultTargetPlatform.name;
  bool get supportsWindowPreferences =>
      {'macos', 'windows', 'linux'}.contains(platform);
  bool get isMobile => platform == 'android' || platform == 'ios';
  bool isTelevision = false;
  bool get supportsExecutablePath => _supportsExecutablePath ?? false;
  bool? _supportsExecutablePath;

  String? notice;
  String? commandError;
  int pid = 0;
  bool loaded = false;
  bool busy = false;
  bool _disposed = false;
  Future<void> _pendingSave = Future.value();
  UnmodifiableListView<ReceiverLog> get logs => UnmodifiableListView(_logs);
  bool get active => {
    'checking',
    'starting',
    'waiting',
    'streaming',
    'stopping',
  }.contains(status);
  bool get editable =>
      loaded && !busy && !{'checking', 'starting', 'stopping'}.contains(status);
  bool get canStart => loaded && !busy && !active;
  bool get canStop => active && status != 'stopping' && !busy;

  Future<void> initialize() async {
    _subscription = repository.events.listen(
      _event,
      onError: (Object error, StackTrace stack) {
        e('Receiver event stream failed', error, stack);
        notice = commandError = _error(error);
        _notify();
      },
    );
    try {
      _snapshot(await repository.snapshot());
      if (autoStart && status == 'stopped') await start(name, path);
    } catch (error, stack) {
      e('Receiver initialization failed', error, stack);
      notice = commandError = _error(error);
      loaded = true;
      _notify();
    }
  }

  void _snapshot(ReceiverState data) {
    final capabilities = data.capabilities;
    if (capabilities.platform.isNotEmpty) _platform = capabilities.platform;
    isTelevision = capabilities.isTelevision;
    _supportsExecutablePath = capabilities.supportsExecutablePath;
    supportsLaunchAtLogin = capabilities.supportsLaunchAtLogin;
    if (status != data.status.name || message != data.message) {
      i('[Receiver state] ${data.status.name}: ${data.message}');
    }
    status = data.status.name;
    message = data.message;
    pid = data.pid;
    final settings = data.settings;
    name = settings.name;
    path = settings.path;
    autoStart = settings.autoStart;
    fastPairing = settings.fastPairing;
    showPlaybackStats = settings.showPlaybackStats;
    if (!showPlaybackStats || data.videoWidth == 0) {
      playbackStats = null;
    }
    videoQuality = settings.videoQuality.value;
    audioOutput = settings.audioOutput.name;
    desktopOptions.addAll(settings.desktopOptions);
    defaultName = data.defaultName;
    if (data.receivingName.trim().isNotEmpty) {
      _receivingName = data.receivingName.trim();
    }
    buildTime = data.buildTime;
    buildVersion = data.buildVersion;
    videoQualities = data.videoQualities;
    screenWidth = data.screenWidth;
    screenHeight = data.screenHeight;
    _activeSettings = data.activeSettings;
    clientName = data.clientName.trim();
    if (clientName!.isEmpty) clientName = null;
    textureId = data.textureId;
    if (data.videoWidth > 0 &&
        data.videoHeight > 0 &&
        (data.videoWidth != videoWidth || data.videoHeight != videoHeight)) {
      i(
        '[Receiver video] Decoded frame ready: ${data.videoWidth}x${data.videoHeight}',
      );
    }
    videoWidth = data.videoWidth;
    videoHeight = data.videoHeight;
    audioPlaying = data.audioPlaying;
    videoPaused = data.videoPaused;
    final byID = <int, ReceiverLog>{for (final log in _logs) log.id: log};
    for (final log in data.logs) {
      _writeLog(log);
      byID[log.id] = log;
    }
    _logs
      ..clear()
      ..addAll(byID.values.toList()..sort((a, b) => a.id.compareTo(b.id)));
    loaded = true;
    _trim();
    _notify();
  }

  void _event(ReceiverEvent event) {
    switch (event.type) {
      case ReceiverEventType.snapshot:
        _snapshot(event.snapshot!);
      case ReceiverEventType.state:
        i('[Receiver state] ${event.status.name}: ${event.message}');
        status = event.status.name;
        message = event.message;
        pid = event.pid;
        if ({'stopped', 'stopping', 'error', 'waiting'}.contains(status)) {
          clientName = null;
          playbackStats = null;
          videoWidth = 0;
          videoHeight = 0;
          audioPlaying = false;
          videoPaused = false;
        }
        _notify();
      case ReceiverEventType.client:
        clientName = event.name.trim();
        if (clientName?.isEmpty ?? false) clientName = null;
        _notify();
      case ReceiverEventType.video:
        if ((event.videoWidth) > 0 &&
            (event.videoHeight) > 0 &&
            (videoWidth != event.videoWidth ||
                videoHeight != event.videoHeight)) {
          i(
            '[Receiver video] Decoded frame ready: '
            '${event.videoWidth}x${event.videoHeight}',
          );
        }
        textureId = event.textureId;
        videoWidth = event.videoWidth;
        videoHeight = event.videoHeight;
        if (!hasVideo) playbackStats = null;
        if (hasVideo) videoPaused = false;
        _notify();
      case ReceiverEventType.media:
        audioPlaying = event.audioPlaying;
        videoPaused = event.videoPaused;
        if (videoPaused) playbackStats = null;
        _notify();
      case ReceiverEventType.playbackStats:
        if (showPlaybackStats && hasVideo && !videoPaused) {
          playbackStats = event.playbackStats;
          _notify();
        }
      case ReceiverEventType.unknown:
        break;
      case ReceiverEventType.log:
        final entry = event.log!;
        _writeLog(entry);
        if (!_logs.any((item) => item.id == entry.id)) _logs.add(entry);
        _trim();
        _notify();
    }
  }

  void _writeLog(ReceiverLog entry) {
    if (entry.id <= _lastWrittenLogID) return;
    _lastWrittenLogID = entry.id;
    i('[Receiver] ${entry.time} ${entry.text}');
  }

  void _trim() {
    if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
  }

  String _error(Object error) => error is PlatformException
      ? error.message ?? 'nativeError'
      : error.toString();

  Future<void> _command(
    Future<void> Function() action, {
    String? success,
  }) async {
    if (busy || _disposed) return;
    busy = true;
    notice = null;
    commandError = null;
    _notify();
    try {
      await action();
      notice = success;
    } catch (error, stack) {
      e('Receiver command failed', error, stack);
      if (error is! PlatformException || error.code != 'cancelled') {
        notice = commandError = _error(error);
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  String? validateName(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return 'nameRequired';
    if (utf8.encode(clean).length > 50 ||
        clean.runes.any((r) => r < 32 || r == 127)) {
      return 'nameInvalid';
    }
    return null;
  }

  Future<void> save(
    String nextName,
    String nextPath, {
    bool? autoStart,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    bool? showPlaybackStats,
    Map<String, bool>? desktopOptions,
  }) {
    final options = desktopOptions == null
        ? null
        : Map<String, bool>.of(desktopOptions);
    return _pendingSave = _pendingSave.then((_) async {
      if (!loaded || _disposed) return;
      final error = validateName(nextName);
      if (error != null) {
        notice = error;
        _notify();
        return;
      }
      await _command(() async {
        if (active) _receivingName ??= name;
        await repository.save(
          nextName.trim(),
          nextPath.trim(),
          autoStart: autoStart ?? this.autoStart,
          fastPairing: fastPairing ?? this.fastPairing,
          showPlaybackStats: showPlaybackStats ?? this.showPlaybackStats,
          videoQuality: supportsVideoQuality
              ? videoQuality ?? this.videoQuality
              : null,
          audioOutput: platform == 'android'
              ? audioOutput ?? this.audioOutput
              : null,
          desktopOptions: options ?? this.desktopOptions,
        );
        name = nextName.trim();
        path = nextPath.trim();
        this.autoStart = autoStart ?? this.autoStart;
        this.fastPairing = fastPairing ?? this.fastPairing;
        this.showPlaybackStats = showPlaybackStats ?? this.showPlaybackStats;
        if (!this.showPlaybackStats) playbackStats = null;
        this.videoQuality = videoQuality ?? this.videoQuality;
        this.audioOutput = audioOutput ?? this.audioOutput;
        if (options != null) this.desktopOptions.addAll(options);
      });
    });
  }

  // The current native protocol has no session-only disconnect command.
  Future<void> disconnect() async {
    if (!canStop) return;
    await _command(repository.disconnect);
  }

  Future<void> start(String nextName, String nextPath) async {
    if (!canStart) return;
    final error = validateName(nextName);
    if (error != null) {
      notice = error;
      _notify();
      return;
    }
    await _command(() async {
      _receivingName = nextName.trim();
      _activeSettings = ReceiverSettings(
        name: nextName.trim(),
        path: nextPath.trim(),
        fastPairing: fastPairing,
        videoQuality: _receiverSettings.videoQuality,
        audioOutput: _receiverSettings.audioOutput,
      );
      await repository.start(nextName.trim(), nextPath.trim());
      name = nextName.trim();
      _receivingName = name;
      path = nextPath.trim();
    });
  }

  Future<void> stop() async {
    if (!canStop) return;
    await _command(repository.stop);
  }

  Future<void> check(String nextPath) async {
    if (!canStart) return;
    await _command(
      () => repository.check(nextPath.trim()),
      success: 'checkPassed',
    );
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  String get logText => _logs.map((entry) => entry.display).join('\n');
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    repository.dispose();
    super.dispose();
  }
}
