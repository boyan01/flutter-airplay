// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Registration is owned by the OS, never replayed from receiver preferences.
class LaunchAtLogin {
  const LaunchAtLogin();
  static const _channel = MethodChannel('tech.soit.flutterairplay/window');

  /// Upgrade an existing app-owned Linux entry without enabling login startup.
  Future<void> migrateLegacyRegistration() async {
    if (Platform.isLinux) await LinuxLoginEntry().migrateLegacyRegistration();
  }

  Future<bool> isEnabled() async => Platform.isLinux
      ? LinuxLoginEntry().isEnabled()
      : (await _channel.invokeMethod<bool>('getLaunchAtLogin'))!;

  Future<bool> setEnabled(bool enabled) async => Platform.isLinux
      ? LinuxLoginEntry().setEnabled(enabled)
      : (await _channel.invokeMethod<bool>('setLaunchAtLogin', enabled))!;
}

/// A single app-owned XDG entry. Injectable paths keep tests out of real startup.
class LinuxLoginEntry {
  LinuxLoginEntry({Map<String, String>? environment, String? executable})
    : environment = environment ?? Platform.environment,
      executable = executable ?? Platform.resolvedExecutable;
  final Map<String, String> environment;
  final String executable;
  static const filename = 'tech.soit.flutterairplay.desktop';
  static const launchArgument = '--launch-at-login';

  String get appPath => environment['APPIMAGE'] ?? executable;
  File get entry {
    final config = environment['XDG_CONFIG_HOME'];
    final home = environment['HOME'];
    if (config != null && p.isAbsolute(config)) {
      return File(p.join(config, 'autostart', filename));
    }
    if (home == null || !p.isAbsolute(home)) {
      throw const FileSystemException(
        'No absolute user configuration directory',
      );
    }
    return File(p.join(home, '.config', 'autostart', filename));
  }

  // Two escape layers: Desktop Entry string escaping, then Exec quoting.
  static String quoteExecutable(String value) {
    if (!p.isAbsolute(value) || RegExp(r'[\x00-\x1f=%]').hasMatch(value)) {
      throw const FileSystemException('Unsupported startup executable path');
    }
    var quoted = value.replaceAllMapped(RegExp(r'[\\"`$]'), (m) => '\\${m[0]}');
    quoted = quoted.replaceAll('\\', '\\\\');
    return '"$quoted"';
  }

  List<File> get systemEntries =>
      ((environment['XDG_CONFIG_DIRS'] ?? '').isEmpty
              ? '/etc/xdg'
              : environment['XDG_CONFIG_DIRS']!)
          .split(':')
          .where(p.isAbsolute)
          .map((directory) => File(p.join(directory, 'autostart', filename)))
          .toList();

  Future<File?> _effectiveEntry() async {
    for (final file in [entry, ...systemEntries]) {
      if (await file.exists()) return file;
    }
    return null;
  }

  Future<bool> isEnabled() async {
    final file = await _effectiveEntry();
    if (file == null) return false;
    final values = <String, String>{};
    var inEntry = false;
    for (final raw in await file.readAsLines()) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inEntry = line == '[Desktop Entry]';
      } else if (inEntry && !line.startsWith('#') && line.contains('=')) {
        final index = line.indexOf('=');
        values[line.substring(0, index).trim()] = line
            .substring(index + 1)
            .trim();
      }
    }
    final desktops = (environment['XDG_CURRENT_DESKTOP'] ?? '')
        .split(':')
        .where((value) => value.isNotEmpty);
    bool matches(String key) => values[key]!
        .split(';')
        .where((value) => value.isNotEmpty)
        .any(desktops.contains);
    return values['Type'] == 'Application' &&
        (!values.containsKey('TryExec') ||
            await _sameExecutable(values['TryExec']!)) &&
        await _sameExecutable(_execPath(values['Exec'] ?? '')) &&
        values['Hidden'] != 'true' &&
        values['X-GNOME-Autostart-enabled'] != 'false' &&
        (!values.containsKey('OnlyShowIn') || matches('OnlyShowIn')) &&
        (!values.containsKey('NotShowIn') || !matches('NotShowIn')) &&
        await _isRunnable(appPath);
  }

  // Accept only the old no-argument entry or our explicit login marker.
  // Do not interpret a shell command, field codes, or arbitrary arguments.
  static String _execPath(String command) {
    final arguments = _execArguments(command);
    if (arguments == null ||
        arguments.isEmpty ||
        arguments.length > 2 ||
        (arguments.length == 2 && arguments[1] != launchArgument)) {
      return '';
    }
    return arguments.first;
  }

  static List<String>? _execArguments(String command) {
    final decoded = command.replaceAllMapped(
      RegExp(r'\\([sntr\\])'),
      (match) => switch (match[1]) {
        's' => ' ',
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => match[1]!,
      },
    );
    final arguments = <String>[];
    var result = StringBuffer();
    var quoted = false, escaped = false, started = false;
    void finish() {
      if (!started) return;
      arguments.add(result.toString());
      result = StringBuffer();
      started = false;
    }

    for (final code in decoded.runes) {
      final character = String.fromCharCode(code);
      if (escaped) {
        result.write(character);
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
        started = true;
      } else if (character == '"') {
        quoted = !quoted;
        started = true;
      } else if (!quoted && RegExp(r'\s').hasMatch(character)) {
        finish();
      } else {
        result.write(character);
        started = true;
      }
    }
    if (quoted || escaped) return null;
    finish();
    if (arguments.any(
      (value) => RegExp(r'%(?!%)').hasMatch(value.replaceAll('%%', '')),
    )) {
      return null;
    }
    return arguments.map((value) => value.replaceAll('%%', '%')).toList();
  }

  /// Upgrade only our exact legacy user entry, preserving all external choices.
  /// A legacy no-argument launch cannot be classified retrospectively and stays
  /// visible; the marker takes effect on the next login.
  Future<void> migrateLegacyRegistration() async {
    final file = entry;
    if (await FileSystemEntity.isLink(file.path) ||
        !await file.exists() ||
        !await isEnabled()) {
      return;
    }
    final original = await file.readAsString();
    final legacy = quoteExecutable(appPath);
    final lines = original.split('\n');
    var inEntry = false, sections = 0;
    final matches = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('[')) {
        inEntry = line == '[Desktop Entry]';
        if (inEntry) sections++;
      } else if (inEntry && RegExp(r'^Exec\s*=').hasMatch(line)) {
        // Whitespace or custom quoting means this was not our generated entry.
        if (lines[i] != 'Exec=$legacy') return;
        matches.add(i);
      }
    }
    if (sections != 1 || matches.length != 1) return;
    lines[matches.single] = 'Exec=$legacy $launchArgument';
    // Avoid overwriting an externally edited or replaced entry while checking.
    if (await FileSystemEntity.isLink(file.path) ||
        await file.readAsString() != original) {
      return;
    }
    await _writeEntry(file, lines.join('\n'));
  }

  Future<bool> _sameExecutable(String value) async {
    if (value.isEmpty) return false;
    final candidates = p.isAbsolute(value)
        ? [value]
        : value.contains('/')
        ? <String>[]
        : (environment['PATH'] ?? '')
              .split(':')
              .where(p.isAbsolute)
              .map((directory) => p.join(directory, value));
    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        return await file.resolveSymbolicLinks() ==
            await File(appPath).resolveSymbolicLinks();
      }
    }
    return false;
  }

  Future<bool> setEnabled(bool enabled) async {
    final file = entry;
    // Reject symlinks rather than touching another application's configuration.
    if (await FileSystemEntity.isLink(file.path)) {
      throw const FileSystemException('Startup entry is a symbolic link');
    }
    if (enabled) {
      final command = quoteExecutable(appPath);
      if (!await _isRunnable(appPath) || appPath.startsWith('/tmp/.mount_')) {
        throw const FileSystemException(
          'Install the application in a permanent location first',
        );
      }
      await file.parent.create(recursive: true);
      await _writeEntry(
        file,
        '[Desktop Entry]\nType=Application\n'
        'Name=Flutter AirPlay\nExec=$command $launchArgument\nTerminal=false\n'
        'Hidden=false\nX-GNOME-Autostart-enabled=true\n',
      );
    } else {
      var systemRegistration = false;
      for (final system in systemEntries) {
        if (await system.exists()) systemRegistration = true;
      }
      if (systemRegistration) {
        await file.parent.create(recursive: true);
        await _writeEntry(
          file,
          '[Desktop Entry]\nType=Application\nHidden=true\n',
        );
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    return isEnabled();
  }

  static Future<bool> _isRunnable(String path) async {
    final stat = await File(path).stat();
    return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
  }

  Future<void> _writeEntry(File file, String contents) async {
    final staging = await file.parent.createTemp('.flutter-airplay-');
    try {
      final temporary = File(p.join(staging.path, filename));
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
