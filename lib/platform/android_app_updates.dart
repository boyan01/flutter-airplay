// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

import 'download_app_updates.dart';

class AndroidAppUpdateService extends DownloadAppUpdateService {
  AndroidAppUpdateService({super.clientFactory, super.temporaryDirectory})
    : super(
        platform: 'android',
        extension: 'apk',
        installer: const MethodChannel(
          'tech.soit.flutterairplay/androidUpdates',
        ),
      );

  static final feed = DownloadAppUpdateService.feed;
  static const androidNamespace = DownloadAppUpdateService.namespace;
  static void validateManifest(Map<String, dynamic> data) =>
      DownloadAppUpdateService.validateManifest(data);
  static Map<String, dynamic>? parseAppcast(String source) =>
      DownloadAppUpdateService.parseAppcast(source);
}
