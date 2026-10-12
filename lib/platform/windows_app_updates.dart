// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download_app_updates.dart';
import 'update_public_key.dart';

class WindowsAppUpdateService extends DownloadAppUpdateService {
  WindowsAppUpdateService({
    super.clientFactory,
    super.temporaryDirectory,
    this.publicKey = updatePublicKey,
  }) : super(
         platform: 'windows',
         extension: 'exe',
         installer: const MethodChannel(
           'tech.soit.flutterairplay/windowsUpdates',
         ),
       );

  final String publicKey;

  @override
  Future<bool> canEnable() async =>
      kReleaseMode &&
      base64Decode(publicKey).length == 32 &&
      await installer.invokeMethod<bool>('canUpdate') == true;

  static Map<String, dynamic>? parseAppcast(String source) =>
      DownloadAppUpdateService.parseAppcast(source, platform: 'windows');

  @override
  Map<String, dynamic>? parseManifest(String source) => parseAppcast(source);

  // The signature binds the version, architecture and installer digest. Hashing
  // the downloaded file then authenticates it without loading it all into RAM.
  static List<int> signaturePayload(Map<String, dynamic> data) => utf8.encode(
    'Flutter AirPlay Windows update\n${data['version']}\n'
    '${data['versionCode']}\n${data['arch']}\n${data['size']}\n${data['sha256']}\n',
  );

  @override
  Future<void> verifyManifest(Map<String, dynamic> data) async {
    DownloadAppUpdateService.validateManifest(data);
    if (data['arch'] != 'x64' ||
        !await Ed25519().verify(
          signaturePayload(data),
          signature: Signature(
            base64Decode(data['edSignature'] as String),
            publicKey: SimplePublicKey(
              base64Decode(publicKey),
              type: KeyPairType.ed25519,
            ),
          ),
        )) {
      throw const FormatException(
        'Windows update signature or architecture is invalid.',
      );
    }
  }
}
