// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Android delivers Back through system navigation after its key sequence.
// Handling goBack here would run the action again when PopScope is notified.
bool isReceiverBackKey(String platform, LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape ||
    (platform != 'android' && key == LogicalKeyboardKey.goBack);

Map<ShortcutActivator, VoidCallback> receiverBackShortcuts(
  String platform,
  VoidCallback onBack,
) => {
  const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
      onBack,
  if (platform != 'android')
    const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false):
        onBack,
};
