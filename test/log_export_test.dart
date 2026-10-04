// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_airplay/log_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Export preserves rotated logs and full timestamps in one archive', () {
    final temporary = Directory.systemTemp.createTempSync(
      'airplay-export-test-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final logs = Directory(p.join(temporary.path, 'logs'))..createSync();
    File(p.join(logs.path, 'log_0.log')).writeAsStringSync('Earlier session\n');
    File(p.join(logs.path, 'log_1.log'))
        .writeAsStringSync('Android video stats: late_drop=12\n');
    File(p.join(logs.path, 'unrelated.txt')).writeAsStringSync('Do not export');
    final exports = Directory(p.join(temporary.path, 'exports'))..createSync();
    final old = File(p.join(exports.path, 'old.zip'))..writeAsStringSync('old');
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    final output = writeLogArchive({
      'logsPath': logs.path,
      'outputDirectory': exports.path,
      'report': '{"version":"0.1.2+3","television":true}',
      'currentLogs': '2026-10-04T12:30:08  Decoder ready',
    });
    final archive = ZipDecoder().decodeBytes(File(output).readAsBytesSync());
    final files = {
      for (final file in archive) file.name: utf8.decode(file.content),
    };
    expect(
      files.keys,
      unorderedEquals([
        'diagnostics.json',
        'current-session.log',
        'logs/log_0.log',
        'logs/log_1.log',
      ]),
    );
    expect(files['logs/log_0.log'], 'Earlier session\n');
    expect(files['logs/log_1.log'], contains('late_drop=12'));
    expect(files['current-session.log'], startsWith('2026-10-04T12:30:08'));
    expect(jsonDecode(files['diagnostics.json']!)['television'], true);
    expect(old.existsSync(), false);
    expect(File(p.join(logs.path, 'log_0.log')).existsSync(), true);
  });

  test('Export still includes diagnostics when no disk logs exist', () {
    final temporary = Directory.systemTemp.createTempSync(
      'airplay-export-empty-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final output = writeLogArchive({
      'logsPath': null,
      'outputDirectory': temporary.path,
      'report': '{}',
      'currentLogs': '',
    });
    final archive = ZipDecoder().decodeBytes(File(output).readAsBytesSync());
    expect(archive.files.map((file) => file.name), [
      'diagnostics.json',
      'current-session.log',
    ]);
  });
}
