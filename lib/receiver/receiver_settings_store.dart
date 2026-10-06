// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'receiver_settings.dart';

/// Single settings writer; native control only keeps a runtime copy.
class ReceiverSettingsStore {
  ReceiverSettingsStore([this._preferences]);
  SharedPreferencesAsync? _preferences;
  SharedPreferencesAsync get preferences =>
      _preferences ??= SharedPreferencesAsync();
  static const storageKey = 'receiver.settings';
  Future<ReceiverSettings?> read() async {
    final stored = await preferences.getString(storageKey);
    if (stored == null) return null;
    final data = jsonDecode(stored);
    if (data is! Map) throw const FormatException('Invalid receiver settings');
    return ReceiverSettings.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> write(ReceiverSettings settings) =>
      preferences.setString(storageKey, jsonEncode(settings.toJson()));
}
