/// UI-locale resolution helpers (§13 wave 2).
///
/// Flutter's basic resolution never infers a Chinese script from the
/// region, so a device reporting plain `zh-TW` (script-less, still common
/// on Android) would land on the base `zh` (Simplified) ARB. Padding the
/// preference list with the region-inferred script first lets the standard
/// algorithm match `zh-Hant` where it should.
library;

import 'dart:ui';

import 'package:flutter/widgets.dart' show basicLocaleListResolution;

import '../domain/script.dart';
import 'gen/app_localizations.dart';

/// A `zh` locale without a script gains the one its region implies;
/// everything else passes through.
Locale padZhLocale(Locale locale) =>
    locale.languageCode == 'zh' && locale.scriptCode == null
        ? Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: zhScriptFor(countryCode: locale.countryCode),
            countryCode: locale.countryCode,
          )
        : locale;

/// Drop-in `localeListResolutionCallback`.
Locale resolveAppLocale(List<Locale>? preferred, Iterable<Locale> supported) =>
    basicLocaleListResolution(
        preferred?.map(padZhLocale).toList(), supported);

/// The strings for code that renders outside any widget tree — a foreground
/// service's notification, a job running with nobody looking. Resolves the
/// system locale the way `main()` does, English when it has no ARB.
AppLocalizations systemL10n() {
  try {
    return lookupAppLocalizations(
        padZhLocale(PlatformDispatcher.instance.locale));
  } catch (_) {
    return lookupAppLocalizations(const Locale('en'));
  }
}
