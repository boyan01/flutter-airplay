// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';

AppLocalizations l10n(BuildContext context) => AppLocalizations.of(context)!;

String localizedMessage(BuildContext context, String value) => switch (value) {
  'nameRequired' => l10n(context).nameRequired,
  'nameInvalid' => l10n(context).nameInvalid,
  'nativeError' => l10n(context).nativeError,
  'saved' => l10n(context).saved,
  'checkPassed' => l10n(context).checkPassed,
  _ => value,
};
