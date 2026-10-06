// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/app_logging.dart';
import 'receiver/receiver_model.dart';

Future<File> exportLogs(ReceiverModel model) async {
  final info = await PackageInfo.fromPlatform();
  final now = DateTime.now();
  final report = {
    'exportedAt': now.toIso8601String(),
    'version': '${info.version}+${info.buildNumber}',
    if (model.buildTime.isNotEmpty) 'buildTime': model.buildTime,
    if (model.platform == 'android') 'videoOutputSelection': 'native',
    'platform': model.platform,
    'operatingSystem': Platform.operatingSystemVersion,
    'television': model.isTelevision,
    'status': model.status,
    'videoQuality': model.videoQuality,
    'screen': '${model.screenWidth}x${model.screenHeight}',
    'receivedVideo': '${model.videoWidth}x${model.videoHeight}',
    'audioPlaying': model.audioPlaying,
    if (model.platform == 'android') 'audioOutputSelection': model.audioOutput,
    'videoPaused': model.videoPaused,
  };
  final currentLogs = model.logs
      .map((entry) => '${entry.time}  ${entry.text}')
      .join('\n');
  final temporary = await getTemporaryDirectory();
  final output = await compute(writeLogArchive, {
    'logsPath': loggingDirectory?.path,
    'outputDirectory': p.join(temporary.path, 'log_exports'),
    'report': const JsonEncoder.withIndent('  ').convert(report),
    'currentLogs': currentLogs,
  });
  return File(output);
}

// Run compression and disk reads outside the playback/UI isolate.
@visibleForTesting
String writeLogArchive(Map<String, String?> input) {
  final directory = Directory(input['outputDirectory']!)
    ..createSync(recursive: true);
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  for (final file in directory.listSync().whereType<File>()) {
    if (file.lastModifiedSync().isBefore(cutoff)) file.deleteSync();
  }
  final output = p.join(
    directory.path,
    'flutter-airplay-logs-${DateTime.now().microsecondsSinceEpoch}.zip',
  );
  final encoder = ZipFileEncoder()..create(output);
  try {
    encoder.addArchiveFile(
      ArchiveFile.string('diagnostics.json', input['report']!),
    );
    encoder.addArchiveFile(
      ArchiveFile.string('current-session.log', input['currentLogs']!),
    );
    final logsPath = input['logsPath'];
    if (logsPath != null && Directory(logsPath).existsSync()) {
      final files = Directory(logsPath)
          .listSync(followLinks: false)
          .whereType<File>()
          .where(
            (file) => RegExp(r'^log_\d+\.log$').hasMatch(p.basename(file.path)),
          )
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      final skipped = <String>[];
      for (final file in files) {
        try {
          final stream = InputFileStream(file.path);
          try {
            encoder.addArchiveFile(
              ArchiveFile.stream('logs/${p.basename(file.path)}', stream),
            );
          } finally {
            stream.closeSync();
          }
        } on FileSystemException {
          // A file may rotate away while the receiver continues logging.
          skipped.add(p.basename(file.path));
        }
      }
      if (skipped.isNotEmpty) {
        encoder.addArchiveFile(
          ArchiveFile.string(
            'export-notes.txt',
            'Logs rotated during export: ${skipped.join(', ')}',
          ),
        );
      }
    }
  } finally {
    encoder.closeSync();
  }
  return output;
}
