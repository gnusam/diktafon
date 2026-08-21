/// The strings that go *inside* exported and synced files (§13).
///
/// Built from the app's localizations in one place: the export screen has a
/// BuildContext to read them from, the laptop-sync job (fork) does not and
/// resolves the locale itself — both must produce the same markdown.
library;

import 'dart:ui' as ui;

import '../services/export/cassette_exporter.dart';
import 'gen/app_localizations.dart';
import 'locale_resolution.dart';

ExportLabels exportLabelsFrom(AppLocalizations l10n) => ExportLabels(
      untitled: l10n.untitledCassette,
      exportedNote: l10n.exportNote,
      summaryHeading: l10n.exportSummaryHeading,
      memoHeading: l10n.memoDivider,
      notTranscribed: l10n.exportNotTranscribed,
      noSpeech: l10n.noSpeech,
    );

/// Same strings, resolved without a widget tree — background jobs render
/// markdown too. Falls back to the built-in English defaults if the system
/// locale resolves to something the generated lookup refuses.
ExportLabels systemExportLabels() {
  try {
    return exportLabelsFrom(lookupAppLocalizations(resolveAppLocale(
      ui.PlatformDispatcher.instance.locales,
      AppLocalizations.supportedLocales,
    )));
  } catch (_) {
    return const ExportLabels();
  }
}
