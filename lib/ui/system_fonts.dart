// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show loadFontFromList;

import 'package:mixin_logger/mixin_logger.dart';

/// Desktop system fonts registered before the first frame is rendered.
class SystemFonts {
  const SystemFonts({this.linuxFamilies = const []});

  final List<String> linuxFamilies;

  String? familyFor(String platform) => switch (platform) {
    'macos' => '.AppleSystemUIFont',
    'linux' when linuxFamilies.isNotEmpty => linuxFamilies.first,
    _ => null,
  };

  List<String>? fallbacksFor(String platform) => switch (platform) {
    'windows' => const ['Microsoft YaHei UI', 'Microsoft YaHei'],
    'linux' when linuxFamilies.isNotEmpty => linuxFamilies.skip(1).toList(),
    _ => null,
  };

  static Future<SystemFonts> initialize() async {
    if (!Platform.isLinux) return const SystemFonts();

    final families = <String>[];
    // Load Chinese fallback even on English desktops: the app supports both
    // languages, independently of the system locale.
    for (final pattern in [
      'sans-serif',
      'sans-serif:lang=zh-cn:charset=4e2d',
    ]) {
      try {
        final family = (await _fontconfig('fc-match', [
          '-f',
          '%{family}',
          pattern,
        ])).split(',').first.trim();
        if (family.isEmpty || families.contains(family)) continue;

        final files = const LineSplitter()
            .convert(await _fontconfig('fc-list', ['-f', '%{file}\n', family]))
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .toSet();
        var loaded = false;
        // Register all available weights/styles rather than only the regular
        // face returned by fc-match.
        for (final path in files) {
          try {
            await loadFontFromList(
              await File(path).readAsBytes(),
              fontFamily: family,
            );
            loaded = true;
          } catch (error, stack) {
            w('Failed to load system font $path: $error\n$stack');
          }
        }
        if (loaded) families.add(family);
      } catch (error, stack) {
        w('Failed to discover system fonts for $pattern: $error\n$stack');
      }
    }
    return SystemFonts(linuxFamilies: List.unmodifiable(families));
  }

  static Future<String> _fontconfig(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(executable, arguments);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw TimeoutException('$executable timed out');
      },
    );
    final output = await stdout;
    final diagnostic = await stderr;
    if (exitCode != 0) {
      throw ProcessException(executable, arguments, diagnostic, exitCode);
    }
    return output;
  }
}
