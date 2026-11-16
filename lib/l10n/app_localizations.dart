// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

// Use the delegates for material_ui rather than the legacy SDK Material types
// emitted by Flutter 3.50's localization generator.
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];
