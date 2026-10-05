// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

import 'receiver_repository.dart';

class ReceiverLog {
  ReceiverLog(Map data)
    : id = data['id'] as int,
      time = data['time'] as String,
      text = data['text'] as String;
  final int id;
  final String time;
  final String text;
  String get display =>
      '${time.length >= 19 ? time.substring(11, 19) : time}  $text';
}

class ReceiverModel extends ChangeNotifier {
  ReceiverModel(this.repository);
  final ReceiverRepository repository;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _logs = <ReceiverLog>[];
  int _lastWrittenLogID = 0;
  String status = 'stopped';
  String message = 'off';
  String name = 'Flutter AirPlay';
  String defaultName = 'Flutter AirPlay';
  Map<String, dynamic> _activeSettings = {};
  bool _applyQueued = false;
  // Add future receiver-run settings here. Immediate application/window
  // preferences do not require a receiver restart.
  Map<String, dynamic> get _receiverSettings => {
    'name': name,
    'path': path,
    if (supportsVideoQuality) 'videoQuality': videoQuality,
    if (platform == 'android') 'audioOutput': audioOutput,
  };
  bool get settingsPending =>
      active &&
      _activeSettings.isNotEmpty &&
      !mapEquals(_activeSettings, _receiverSettings);
  String? _receivingName;
  String get receivingName => active ? _receivingName ?? name : name;
  String path = '';
  bool autoStart = true;
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

  void _snapshot(Map<String, dynamic> data) {
    final capabilities = data['capabilities'];
    if (capabilities is Map) {
      _platform = capabilities['platform'] as String? ?? _platform;
      isTelevision = capabilities['isTelevision'] as bool? ?? false;
      _supportsExecutablePath = capabilities['supportsExecutablePath'] as bool?;
      supportsLaunchAtLogin =
          capabilities['supportsLaunchAtLogin'] as bool? ?? false;
    }
    if (status != data['status'] || message != data['message']) {
      i('[Receiver state] ${data['status']}: ${data['message']}');
    }
    status = data['status'] as String;
    message = data['message'] as String;
    pid = data['pid'] as int? ?? 0;
    name = data['name'] as String;
    defaultName = data['defaultName'] as String? ?? defaultName;
    final receivingName = (data['receivingName'] as String?)?.trim();
    if (receivingName?.isNotEmpty ?? false) _receivingName = receivingName;
    path = data['path'] as String? ?? '';
    autoStart = data['autoStart'] as bool? ?? true;
    videoQuality = data['videoQuality'] as String? ?? videoQuality;
    audioOutput = data['audioOutput'] as String? ?? audioOutput;
    buildTime = data['buildTime'] as String? ?? buildTime;
    buildVersion = data['buildVersion'] as String? ?? buildVersion;
    videoQualities =
        (data['videoQualities'] as List?)?.cast<String>() ?? videoQualities;
    screenWidth = data['screenWidth'] as int? ?? screenWidth;
    screenHeight = data['screenHeight'] as int? ?? screenHeight;
    final activeSettings = data['activeSettings'];
    if (activeSettings is Map) {
      _activeSettings = Map<String, dynamic>.from(activeSettings);
    }
    clientName = (data['clientName'] as String?)?.trim();
    if (clientName?.isEmpty ?? false) clientName = null;
    for (final key in desktopOptions.keys.toList()) {
      desktopOptions[key] = data[key] as bool? ?? desktopOptions[key]!;
    }
    textureId = data['textureId'] as int? ?? -1;
    final nextWidth = data['videoWidth'] as int? ?? 0;
    final nextHeight = data['videoHeight'] as int? ?? 0;
    if (nextWidth > 0 &&
        nextHeight > 0 &&
        (nextWidth != videoWidth || nextHeight != videoHeight)) {
      i('[Receiver video] Decoded frame ready: ${nextWidth}x$nextHeight');
    }
    videoWidth = nextWidth;
    videoHeight = nextHeight;
    audioPlaying = data['audioPlaying'] as bool? ?? false;
    videoPaused = data['videoPaused'] as bool? ?? false;
    final byID = <int, ReceiverLog>{for (final log in _logs) log.id: log};
    for (final entry in data['logs'] as List? ?? const []) {
      final log = ReceiverLog(entry as Map);
      _writeLog(log);
      byID[log.id] = log;
    }
    _logs
      ..clear()
      ..addAll(byID.values.toList()..sort((a, b) => a.id.compareTo(b.id)));
    loaded = true;
    _trim();
    _notify();
    _scheduleSettingsApply();
  }

  void _event(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'snapshot':
        _snapshot(Map<String, dynamic>.from(event['data'] as Map));
      case 'state':
        i('[Receiver state] ${event['status']}: ${event['message']}');
        status = event['status'] as String;
        message = event['message'] as String;
        pid = event['pid'] as int? ?? 0;
        if ({'stopped', 'stopping', 'error', 'waiting'}.contains(status)) {
          clientName = null;
          videoWidth = 0;
          videoHeight = 0;
          audioPlaying = false;
          videoPaused = false;
        }
        _notify();
        _scheduleSettingsApply();
      case 'client':
        clientName = (event['name'] as String?)?.trim();
        if (clientName?.isEmpty ?? false) clientName = null;
        _notify();
      case 'video':
        if ((event['videoWidth'] as int) > 0 &&
            (event['videoHeight'] as int) > 0 &&
            (videoWidth != event['videoWidth'] ||
                videoHeight != event['videoHeight'])) {
          i(
            '[Receiver video] Decoded frame ready: '
            '${event['videoWidth']}x${event['videoHeight']}',
          );
        }
        textureId = event['textureId'] as int;
        videoWidth = event['videoWidth'] as int;
        videoHeight = event['videoHeight'] as int;
        if (hasVideo) videoPaused = false;
        _notify();
      case 'media':
        audioPlaying = event['audioPlaying'] as bool;
        videoPaused = event['videoPaused'] as bool;
        _notify();
      case 'log':
        final entry = ReceiverLog(event['entry'] as Map);
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
      _scheduleSettingsApply();
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

  // macOS stop acknowledges the request before its owned process exits.
  Future<void> _stopAndWait() async {
    final stopped = Completer<void>();
    void changed() {
      if (status == 'stopped' && !stopped.isCompleted) stopped.complete();
    }

    addListener(changed);
    try {
      await repository.stop();
      changed();
      await stopped.future.timeout(const Duration(seconds: 8));
    } finally {
      removeListener(changed);
    }
  }

  Future<void> _waitUntilReady() async {
    final ready = Completer<void>();
    void changed() {
      if (status != 'starting' && !ready.isCompleted) ready.complete();
    }

    addListener(changed);
    try {
      changed();
      await ready.future.timeout(const Duration(seconds: 8));
      if (status != 'waiting' && status != 'streaming') {
        throw PlatformException(code: 'receiver_error', message: message);
      }
    } finally {
      removeListener(changed);
    }
  }

  Future<void> save(
    String nextName,
    String nextPath, {
    bool? autoStart,
    String? videoQuality,
    String? audioOutput,
    Map<String, bool>? desktopOptions,
  }) {
    final options = desktopOptions == null
        ? null
        : Map<String, bool>.of(desktopOptions);
    return _pendingSave = _pendingSave.then((_) async {
      if (!editable || _disposed) return;
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
        this.videoQuality = videoQuality ?? this.videoQuality;
        this.audioOutput = audioOutput ?? this.audioOutput;
        if (options != null) this.desktopOptions.addAll(options);
      });
    });
  }

  // The current native protocol has no session-only disconnect command.
  Future<void> disconnect() async {
    if (!canStop) return;
    await _command(() async {
      await _stopAndWait();
      _receivingName = name;
      _activeSettings = _receiverSettings;
      await repository.start(name, path);
    });
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
      _activeSettings = {
        ..._receiverSettings,
        'name': nextName.trim(),
        'path': nextPath.trim(),
      };
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

  void _scheduleSettingsApply() {
    if (_disposed ||
        !settingsPending ||
        status != 'waiting' ||
        busy ||
        _applyQueued) {
      return;
    }
    _applyQueued = true;
    _pendingSave = _pendingSave.then((_) async {
      try {
        if (_disposed || status != 'waiting' || !settingsPending) return;
        await _command(() async {
          final applied = await repository.applySettings();
          // Read the host's actual runtime settings, including deferred updates
          // and discovery name changes, rather than assuming the restart won.
          _snapshot(await repository.snapshot());
          if (applied && status == 'starting') {
            await _waitUntilReady();
            _snapshot(await repository.snapshot());
          }
        });
      } finally {
        _applyQueued = false;
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
