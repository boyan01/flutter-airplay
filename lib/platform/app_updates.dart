// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_app_updates.dart';

enum UpdateStatus {
  idle,
  checking,
  available,
  downloading,
  extracting,
  ready,
  installing,
  error,
}

/// The host owns verification, installation and application termination.
class AppUpdateService {
  static const channel = MethodChannel('tech.soit.flutterairplay/updates');

  Future<Map<String, dynamic>> _call(String method) async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>(method) ?? {},
      );

  Future<Map<String, dynamic>> initialize() => _call('initialize');
  Future<Map<String, dynamic>> checkForUpdates() => _call('checkForUpdates');
  Future<Map<String, dynamic>> showUpdate() => _call('showUpdate');
  Future<Map<String, dynamic>> installUpdate() => _call('installUpdate');
  Future<Map<String, dynamic>> cancelUpdate() => _call('cancelUpdate');

  void listen(ValueChanged<Map<String, dynamic>>? listener) {
    channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method == 'updateState' && call.arguments is Map) {
                listener(Map<String, dynamic>.from(call.arguments as Map));
              }
            },
    );
  }
}

class AppUpdatePreferences {
  late final _preferences = SharedPreferencesAsync();
  Future<bool> readAutomaticallyCheck() async =>
      await _preferences.getBool('updates.automaticallyCheck') ?? true;
  Future<void> writeAutomaticallyCheck(bool value) =>
      _preferences.setBool('updates.automaticallyCheck', value);
  Future<DateTime?> readLastChecked() async {
    final value = await _preferences.getString('updates.lastChecked');
    return value == null ? null : DateTime.tryParse(value);
  }

  Future<void> writeLastChecked(DateTime value) => _preferences.setString(
    'updates.lastChecked',
    value.toUtc().toIso8601String(),
  );
}

/// One scheduler and one state shared by the window, settings and tray.
class AppUpdates extends ChangeNotifier {
  AppUpdates({
    AppUpdateService? service,
    AppUpdatePreferences? preferences,
    DateTime Function()? now,
    this.startupDelay = const Duration(seconds: 30),
    this.checkInterval = const Duration(hours: 24),
    this.retryInterval = const Duration(hours: 1),
  }) : _service =
           service ??
           (defaultTargetPlatform == TargetPlatform.android
               ? AndroidAppUpdateService()
               : AppUpdateService()),
       _preferences = preferences ?? AppUpdatePreferences(),
       _now = now ?? DateTime.now;

  final AppUpdateService _service;
  final AppUpdatePreferences _preferences;
  final DateTime Function() _now;
  final Duration startupDelay, checkInterval, retryInterval;
  Timer? _timer;
  DateTime? _retryAfter, _startupAfter;
  bool _disposed = false, _initializing = false, _operationPending = false;
  bool _nativeCanCheck = false, _nativeCanShow = false;
  bool _nativeCanInstall = false, _nativeCanCancel = false;
  int _eventRevision = 0;
  int _nativeRevision = -1;
  bool initialized = false, supported = false, enabled = false;
  bool requiresSystemInstall = false;
  bool automaticallyCheckForUpdates = true, savingPreference = false;
  UpdateStatus status = UpdateStatus.idle;
  String? version, error, unavailableReason, releaseNotes;
  double? progress;
  DateTime? lastChecked;

  bool get checking => status == UpdateStatus.checking;
  bool get hasUpdate => version != null;
  bool get canCheck =>
      enabled && !checking && !_operationPending && _nativeCanCheck;
  bool get canShowUpdate => enabled && !_operationPending && _nativeCanShow;
  bool get canInstall => enabled && !_operationPending && _nativeCanInstall;
  bool get canCancel => enabled && !_operationPending && _nativeCanCancel;

  Future<void> initialize(String platform) async {
    if (initialized || _initializing || _disposed) return;
    requiresSystemInstall = platform == 'android';
    supported = platform == 'macos' || platform == 'android';
    if (!supported) {
      initialized = true;
      notifyListeners();
      return;
    }
    _initializing = true;
    try {
      automaticallyCheckForUpdates = await _preferences
          .readAutomaticallyCheck();
      lastChecked = await _preferences.readLastChecked();
      if (_disposed) return;
      _service.listen((snapshot) {
        _eventRevision++;
        _apply(snapshot);
      });
      final snapshot = await _service.initialize();
      if (_disposed) return;
      _startupAfter = _now().add(startupDelay);
      _apply(snapshot);
    } catch (failure) {
      if (_disposed) return;
      enabled = false;
      unavailableReason = _message(failure);
    } finally {
      _initializing = false;
      if (!_disposed) {
        initialized = true;
        _schedule();
        notifyListeners();
      }
    }
  }

  String _message(Object failure) => failure is PlatformException
      ? failure.message ?? failure.code
      : failure.toString();

  void _apply(Map<String, dynamic> snapshot) {
    if (_disposed) return;
    final revision = snapshot['revision'] as int?;
    if (revision != null) {
      if (revision < _nativeRevision) return;
      _nativeRevision = revision;
    }
    final wasChecking = status == UpdateStatus.checking;
    enabled = snapshot['enabled'] == true;
    unavailableReason = snapshot['reason'] as String?;
    status = UpdateStatus.values.firstWhere(
      (value) => value.name == snapshot['status'],
      orElse: () => UpdateStatus.idle,
    );
    version = snapshot['version'] as String?;
    error = snapshot['error'] as String?;
    releaseNotes = snapshot['releaseNotes'] as String?;
    progress = (snapshot['progress'] as num?)?.toDouble();
    final capabilities = snapshot['capabilities'];
    _nativeCanCheck =
        capabilities is Map && capabilities['checkForUpdates'] == true;
    _nativeCanShow = capabilities is Map && capabilities['showUpdate'] == true;
    _nativeCanInstall =
        capabilities is Map && capabilities['installUpdate'] == true;
    _nativeCanCancel =
        capabilities is Map && capabilities['cancelUpdate'] == true;
    if (wasChecking && status != UpdateStatus.checking) {
      if (error == null &&
          (status == UpdateStatus.idle || status == UpdateStatus.available)) {
        lastChecked = _now();
        _retryAfter = null;
        unawaited(_saveLastChecked(lastChecked!));
      } else {
        _retryAfter = _now().add(retryInterval);
      }
    }
    _schedule();
    notifyListeners();
  }

  Future<void> _saveLastChecked(DateTime value) async {
    try {
      await _preferences.writeLastChecked(value);
    } catch (_) {
      // An optional timestamp must not discard a successful update result.
    }
  }

  Future<void> setAutomaticallyCheckForUpdates(bool value) async {
    if (!enabled || savingPreference || _disposed) return;
    savingPreference = true;
    notifyListeners();
    try {
      await _preferences.writeAutomaticallyCheck(value);
      if (_disposed) return;
      automaticallyCheckForUpdates = value;
      error = null;
    } catch (failure) {
      if (!_disposed) error = _message(failure);
    } finally {
      if (!_disposed) {
        savingPreference = false;
        _schedule();
        notifyListeners();
      }
    }
  }

  Future<void> check() => _check();

  Future<void> _check() async {
    if (!canCheck || _disposed) return;
    _operationPending = true;
    status = UpdateStatus.checking;
    error = null;
    _timer?.cancel();
    notifyListeners();
    try {
      final revision = _eventRevision;
      final snapshot = await _service.checkForUpdates();
      if (!_disposed && revision == _eventRevision) _apply(snapshot);
    } catch (failure) {
      if (!_disposed) {
        status = UpdateStatus.error;
        error = _message(failure);
        _retryAfter = _now().add(retryInterval);
      }
    } finally {
      _operationPending = false;
      if (!_disposed) {
        _schedule();
        notifyListeners();
      }
    }
  }

  Future<void> showUpdate() => _perform(_service.showUpdate, canShowUpdate);
  Future<void> install() => _perform(_service.installUpdate, canInstall);
  Future<void> cancel() => _perform(_service.cancelUpdate, canCancel);

  Future<void> _perform(
    Future<Map<String, dynamic>> Function() action,
    bool allowed,
  ) async {
    if (!allowed || _disposed) return;
    _operationPending = true;
    error = null;
    notifyListeners();
    try {
      final revision = _eventRevision;
      final snapshot = await action();
      if (!_disposed && revision == _eventRevision) _apply(snapshot);
    } catch (failure) {
      if (!_disposed) error = _message(failure);
    } finally {
      _operationPending = false;
      if (!_disposed) {
        _schedule();
        notifyListeners();
      }
    }
  }

  DateTime get _nextCheck {
    final now = _now();
    var next = _retryAfter ?? lastChecked?.add(checkInterval) ?? now;
    // Ignore an old clock value after the system clock moves backwards.
    if (lastChecked != null && lastChecked!.isAfter(now)) next = now;
    if (_startupAfter != null && _startupAfter!.isAfter(next)) {
      next = _startupAfter!;
    }
    return next;
  }

  /// Called on foreground activation and wake; never presents update UI.
  void checkIfDue() {
    if (_disposed ||
        !initialized ||
        !automaticallyCheckForUpdates ||
        !canCheck) {
      return;
    }
    if (!_nextCheck.isAfter(_now())) unawaited(_check());
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed ||
        !initialized ||
        !automaticallyCheckForUpdates ||
        !canCheck) {
      return;
    }
    final delay = _nextCheck.difference(_now());
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_check()),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    if (supported) _service.listen(null);
    super.dispose();
  }
}
