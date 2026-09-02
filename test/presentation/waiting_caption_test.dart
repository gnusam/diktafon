/// What an untranscribed memo says while it waits (§14, plus the fork's
/// battery gate).
///
/// The battery case earned its own test the hard way: on the device the
/// caption read "transcribing again above 15%" while the phone sat at 15% —
/// the level it had stopped at, printed where the level it *resumes* at
/// belongs. The widget now takes a bool, so there is no percentage in reach
/// for it to print by mistake; this pins the copy that goes with it.
library;

import 'package:diktafon/domain/models.dart';
import 'package:diktafon/domain/tape.dart';
import 'package:diktafon/l10n/l10n.dart';
import 'package:diktafon/presentation/theme/theme.dart';
import 'package:diktafon/presentation/widgets/transcript_view.dart';
import 'package:diktafon/services/system/power_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tape = Tape([
    Memo(
      id: 'm1',
      cassetteId: 'c1',
      filePath: '/dev/null',
      durationMs: 4000,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000000),
      // Captured and playable, nothing enriched yet — the state every
      // caption below describes.
      status: MemoStatus.stored,
    ),
  ]);

  Widget app({required bool modelReady, required bool powerHeld}) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: TranscriptView(
            tape: tape,
            colorSeed: 0,
            globalMs: 0,
            currentMemoIndex: 0,
            playing: false,
            modelReady: modelReady,
            powerHeld: powerHeld,
          ),
        ),
      );

  testWidgets('gate open, model there → the plain queued caption',
      (tester) async {
    await tester.pumpWidget(app(modelReady: true, powerHeld: false));
    expect(find.text('queued for transcription…'), findsOneWidget);
  });

  testWidgets('gate shut → the caption names the level work RESUMES at',
      (tester) async {
    await tester.pumpWidget(app(modelReady: true, powerHeld: true));

    expect(find.textContaining('waiting for power'), findsOneWidget);
    expect(find.textContaining('above $lowBatteryPercent%'), findsOneWidget,
        reason: 'the threshold, not whatever the battery happens to read');
    expect(find.text('queued for transcription…'), findsNothing);
  });

  testWidgets('a missing model outranks a flat battery', (tester) async {
    // Both stand in the way, but only one is something the user can act on.
    await tester.pumpWidget(app(modelReady: false, powerHeld: true));

    expect(find.textContaining('waiting for the transcription model'),
        findsOneWidget);
    expect(find.textContaining('waiting for power'), findsNothing);
  });
}
