// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../widgets/receiver_strings.dart';

String qualityLabel(BuildContext context, String value) => switch (value) {
  '720' => l10n(context).quality720,
  '1080' => l10n(context).quality1080,
  '1440' => l10n(context).quality1440,
  '2160' => l10n(context).quality2160,
  _ => l10n(context).qualityAuto,
};

String audioOutputLabel(BuildContext context, String value) => switch (value) {
  'aaudio' => l10n(context).audioOutputAAudio,
  'audiotrack' => l10n(context).audioOutputTrack,
  _ => l10n(context).audioOutputAuto,
};
