/// Sends one synthetic memo through the app's own sync client (fork).
///
///     dart run tools/laptop-receiver/sync_probe.dart <url> [label]
///
/// The url is what the app takes: `https://user:pass@host[/base][#token]`.
/// Useful for proving a receiver — or the whole tunnel — before touching
/// the phone, and for telling "the app is wrong" apart from "the tunnel is
/// wrong" when something stops arriving. It is the real client and the real
/// payload builder, so the framing on the wire is the phone's.
library;

import 'dart:io';

import 'package:diktafon/domain/models.dart';
import 'package:diktafon/services/export/cassette_exporter.dart';
import 'package:diktafon/services/sync/laptop_sync.dart';
import 'package:diktafon/services/sync/sync_payload.dart';
import 'package:diktafon/services/sync/sync_target.dart';

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tools/laptop-receiver/sync_probe.dart '
        '<url> [cassette-label]');
    return 64;
  }
  final target = SyncTarget.parse(args.first);
  if (target == null) {
    stderr.writeln('not an address this can send to: ${args.first}');
    return 64;
  }
  final label = args.length > 1 ? args[1] : 'probe';
  final sync = LaptopSync();

  stdout.writeln('→ ${target.displayName}');
  try {
    stdout.writeln('  ping: ${await sync.ping(target)}');
  } on SyncException catch (e) {
    stderr.writeln('  ping failed: $e');
    return 1;
  }

  final now = DateTime.now();
  final audio = File('${Directory.systemTemp.path}/diktafon-probe.m4a')
    ..writeAsBytesSync(List<int>.generate(4096, (i) => i % 251));
  final memo = Memo(
    id: 'probe-${now.millisecondsSinceEpoch}',
    cassetteId: 'probe-cassette',
    filePath: audio.path,
    durationMs: 4200,
    createdAt: now,
    status: MemoStatus.ready,
    detectedLang: 'fr',
    memoSummary: 'Mémo de test envoyé par sync_probe.',
    transcript: Transcript(languageCode: 'fr', segments: [
      Segment(startMs: 0, endMs: 1200, words: const [
        Word(text: 'ceci', startMs: 0, endMs: 300),
        Word(text: 'est', startMs: 300, endMs: 600),
        Word(text: 'un', startMs: 600, endMs: 800),
        Word(text: 'test', startMs: 800, endMs: 1200),
      ]),
    ]),
  );

  try {
    await sync.uploadMemo(
      target,
      manifest: buildMemoPayload(
        cassette: Cassette(
          id: memo.cassetteId,
          label: label,
          titleIsUserSet: true,
          colorSeed: 42,
          summary: null,
          summaryUpdatedAt: null,
          createdAt: now,
          updatedAt: now,
        ),
        memo: memo,
        labels: const ExportLabels(),
        audioExtension: '.m4a',
        audioBytes: audio.lengthSync(),
        audioSha256: await fileSha256(audio),
      ),
      audio: audio,
      audioFieldName: '${memo.id}.m4a',
    );
    stdout.writeln('  sent memo ${memo.id} to cassette "$label"');
    return 0;
  } on SyncException catch (e) {
    stderr.writeln('  upload failed: $e');
    return 1;
  } finally {
    audio.deleteSync();
  }
}
