// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  String status = 'stopped';
  String message = '接收器未启动';
  String name = 'Flutter AirPlay';
  String path = '';
  int textureId = -1, videoWidth = 0, videoHeight = 0;
  bool get hasVideo => textureId >= 0 && videoWidth > 0 && videoHeight > 0;

  String? notice;
  int pid = 0;
  bool loaded = false;
  bool busy = false;
  bool _disposed = false;
  UnmodifiableListView<ReceiverLog> get logs => UnmodifiableListView(_logs);
  bool get active =>
      {
        'checking',
        'starting',
        'waiting',
        'streaming',
        'stopping',
      }.contains(status) ||
      pid > 0;
  bool get editable => loaded && !busy && !active;
  bool get canStart => editable;
  bool get canStop => active && status != 'stopping' && !busy;

  Future<void> initialize() async {
    _subscription = repository.events.listen(
      _event,
      onError: (Object error) {
        notice = _error(error);
        _notify();
      },
    );
    try {
      _snapshot(await repository.snapshot());
    } catch (error) {
      notice = _error(error);
      loaded = true;
      _notify();
    }
  }

  void _snapshot(Map<String, dynamic> data) {
    status = data['status'] as String;
    message = data['message'] as String;
    pid = data['pid'] as int;
    if (!loaded) {
      name = data['name'] as String;
      path = data['path'] as String;
    }
    textureId = data['textureId'] as int? ?? -1;
    videoWidth = data['videoWidth'] as int? ?? 0;
    videoHeight = data['videoHeight'] as int? ?? 0;
    final byID = <int, ReceiverLog>{for (final log in _logs) log.id: log};
    for (final entry in data['logs'] as List) {
      final log = ReceiverLog(entry as Map);
      byID[log.id] = log;
    }
    _logs
      ..clear()
      ..addAll(byID.values.toList()..sort((a, b) => a.id.compareTo(b.id)));
    loaded = true;
    _trim();
    _notify();
  }

  void _event(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'snapshot':
        _snapshot(Map<String, dynamic>.from(event['data'] as Map));
      case 'state':
        status = event['status'] as String;
        message = event['message'] as String;
        pid = event['pid'] as int;
        if ({'stopped', 'stopping', 'error', 'waiting'}.contains(status)) {
          videoWidth = 0;
          videoHeight = 0;
        }
        _notify();
      case 'video':
        textureId = event['textureId'] as int;
        videoWidth = event['videoWidth'] as int;
        videoHeight = event['videoHeight'] as int;
        _notify();
      case 'log':
        final entry = ReceiverLog(event['entry'] as Map);
        if (!_logs.any((item) => item.id == entry.id)) _logs.add(entry);
        _trim();
        _notify();
    }
  }

  void _trim() {
    if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
  }

  String _error(Object error) => error is PlatformException
      ? error.message ?? '原生接收器操作失败'
      : error.toString();

  Future<void> _command(
    Future<void> Function() action, {
    String? success,
  }) async {
    if (busy || _disposed) return;
    busy = true;
    notice = null;
    _notify();
    try {
      await action();
      notice = success;
    } catch (error) {
      notice = _error(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  String? validateName(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return '请输入设备名';
    if (utf8.encode(clean).length > 50 ||
        clean.runes.any((r) => r < 32 || r == 127)) {
      return '设备名最多 50 个 UTF-8 字节，不能含换行';
    }
    return null;
  }

  Future<void> save(String nextName, String nextPath) async {
    if (!editable) return;
    final error = validateName(nextName);
    if (error != null) {
      notice = error;
      _notify();
      return;
    }
    await _command(() async {
      await repository.save(nextName.trim(), nextPath.trim());
      name = nextName.trim();
      path = nextPath.trim();
    }, success: '设置已保存');
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
      await repository.start(nextName.trim(), nextPath.trim());
      name = nextName.trim();
      path = nextPath.trim();
    });
  }

  Future<void> stop() async {
    if (!canStop) return;
    await _command(repository.stop);
  }

  Future<void> check(String nextPath) async {
    if (!editable) return;
    await _command(
      () => repository.check(nextPath.trim()),
      success: '依赖检查通过，可以启动接收器',
    );
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  String get logText => _logs.map((entry) => entry.display).join('\n');
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
