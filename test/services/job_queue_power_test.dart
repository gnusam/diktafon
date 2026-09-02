/// The battery gate (fork addition): whisper and the LLM hold below a
/// threshold on battery — and, just as deliberately, nothing else does.
///
/// The line these tests defend is the one that is easy to get wrong. An
/// energy-saving feature that also held back the upload would recreate the
/// symptom this fork exists to remove — "les données ne sont pas
/// automatiquement push" — with a battery percentage as the trigger instead
/// of a frozen process. So the upload is exercised against a real receiver
/// on loopback with the gate shut, not asserted by inspection.
library;

import 'dart:io';

import 'package:diktafon/data/db/database.dart';
import 'package:diktafon/data/repositories/cassette_repository.dart';
import 'package:diktafon/data/repositories/memo_repository.dart';
import 'package:diktafon/data/repositories/settings_repository.dart';
import 'package:diktafon/domain/models.dart';
import 'package:diktafon/services/processing/job_queue.dart';
import 'package:diktafon/services/providers/transcription_provider.dart'
    show ModelStatus;
import 'package:diktafon/services/sync/laptop_sync.dart';
import 'package:diktafon/services/system/power_state.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job_queue_sync_test.dart' show FakeTranscoder, StubReceiver;
import 'job_queue_test.dart'
    show FakeSummarizationProvider, FakeTranscriptionProvider, shortTranscript;

void main() {
  group('PowerState — the gate itself', () {
    test('opens above the threshold, shuts below it, on battery', () {
      expect(const PowerState(level: 21).allowsInference, isTrue);
      expect(const PowerState(level: 20).allowsInference, isTrue,
          reason: 'the threshold is the last allowed level, '
              'not the first refused one');
      expect(const PowerState(level: 19).allowsInference, isFalse);
    });

    test('a charger overrides it at any level', () {
      expect(const PowerState(level: 3, charging: true).allowsInference, isTrue);
      expect(const PowerState(level: 3, charging: true).holdingAt, isNull);
    });

    test('an unreadable gauge is not an empty battery', () {
      // The platform sends -1 for a gauge it cannot read; that arrives here
      // as null. Refusing to transcribe because a ROM will not say what the
      // battery is doing would be a worse bug than the one prevented.
      expect(const PowerState().allowsInference, isTrue);
      expect(PowerState.unknown.allowsInference, isTrue);
    });

    test('holdingAt names the level only while shut', () {
      expect(const PowerState(level: 14).holdingAt, 14);
      expect(const PowerState(level: 44).holdingAt, isNull);
    });
  });

  group('the gate in the drain', () {
    late Directory work;
    late AppDatabase db;
    late MemoRepository memos;
    late CassetteRepository cassettes;
    late SettingsRepository settings;
    late FakeTranscriptionProvider engine;
    late StubReceiver receiver;
    late JobQueue queue;
    late bool powered;

    setUp(() async {
      work = Directory.systemTemp.createTempSync('dk_power_');
      db = AppDatabase.forTesting(NativeDatabase.memory());
      memos = MemoRepository(db);
      cassettes = CassetteRepository(db);
      settings = SettingsRepository(db);
      engine = FakeTranscriptionProvider(
          result: shortTranscript('fr', 'bonjour le laptop'));
      receiver = await StubReceiver.start();
      powered = false; // flat battery, on battery, unless a test says else
      queue = JobQueue(
        db,
        memos,
        cassettes,
        settings,
        () => engine,
        () => FakeSummarizationProvider(status: ModelStatus.notInstalled),
        transcoder: () => FakeTranscoder(),
        sync: LaptopSync.new,
        inferenceAllowed: () => powered,
        retryDelayUnit: Duration.zero,
      );
      await db.into(db.cassettes).insert(CassetteRow(
            id: 'c1',
            label: 'life',
            titleIsUserSet: true,
            colorSeed: 7,
            createdAt: 0,
            updatedAt: 0,
          ));
      await settings.setSyncUrl(receiver.url);
      await settings.setSyncAuto(true);
    });

    tearDown(() async {
      queue.dispose();
      await receiver.close();
      await db.close();
      work.deleteSync(recursive: true);
    });

    var seeded = 0;
    Future<Memo> seedMemo(String id, {String ext = '.m4a'}) async {
      final file = File('${work.path}/$id$ext')..writeAsBytesSync([1, 2, 3, 4]);
      final memo = Memo(
        id: id,
        cassetteId: 'c1',
        filePath: file.path,
        durationMs: 4000,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000 + seeded++),
        status: MemoStatus.stored,
      );
      await memos.insert(memo);
      return memo;
    }

    Future<MemoRow> memoRow(String id) =>
        (db.select(db.memos)..where((m) => m.id.equals(id))).getSingle();

    test('a flat battery parks the transcription, and keeps the memo',
        () async {
      await seedMemo('m1');
      await queue.enqueueTranscription('m1');
      await queue.drain();

      expect(engine.calls, 0);
      expect((await db.select(db.jobs).get()).single.type,
          JobType.transcribe.name);
      // Honest status: `stored`, never "transcribing…" over a stage that is
      // not running, and never `failed` — nothing failed.
      expect((await memoRow('m1')).status, MemoStatus.stored.name);
    });

    test('the charger releases it, with no restart and no gesture', () async {
      await seedMemo('m1');
      await queue.enqueueTranscription('m1');
      await queue.drain();
      expect(engine.calls, 0);

      powered = true;
      await queue.drain();

      expect(engine.calls, 1);
      expect((await memoRow('m1')).status, MemoStatus.ready.name);
    });

    test('the gate is re-read per pass, so a charger mid-backlog is enough',
        () async {
      for (final id in ['m1', 'm2', 'm3']) {
        await seedMemo(id);
        await queue.enqueueTranscription(id);
      }
      powered = true;
      await queue.drain();

      expect(engine.calls, 3, reason: 'all three ride the same drain');
    });

    test('the upload is NEVER gated — a memo already enriched goes at 3 %',
        () async {
      // The whole point of the feature's shape. Transcribe once with power,
      // so the memo reaches its final content and earns an upload job…
      await seedMemo('m1');
      powered = true;
      await queue.enqueueTranscription('m1');
      await queue.drain();
      expect(receiver.uploads, hasLength(1));

      // …then flatten the battery and hand it something new to send. The
      // edit un-marks the memo (the laptop's copy describes the old words),
      // which is exactly the "send it again" path.
      powered = false;
      await queue.enqueueUploads(force: true);
      await queue.drain();

      expect(receiver.uploads.length, greaterThan(1),
          reason: 'a flat battery must never hold back the laptop');
      expect((await memoRow('m1')).syncedAt, isNotNull);
    });

    test('the transcode still runs flat — the .m4a is what travels',
        () async {
      // Hardware MediaCodec, seconds of work. Gating it would strand the
      // archival file the upload is supposed to carry.
      await seedMemo('m1', ext: '.wav');
      await queue.enqueueTranscode('m1');
      await queue.drain();

      expect((await memoRow('m1')).filePath, endsWith('.m4a'),
          reason: 'transcode is not an inference stage');
    });
  });
}
