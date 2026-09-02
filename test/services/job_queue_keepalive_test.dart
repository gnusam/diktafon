/// Background progress (fork addition): the keep-alive the queue holds while
/// it works.
///
/// Durability was never the gap — jobs survive a kill. Progress was: a
/// backgrounded Android app is a cached app and the OS freezes its threads,
/// so a memo recorded and left behind stopped mid-whisper and never reached
/// the laptop. These tests pin down when the queue asks to stay foreground,
/// and — just as important — when it lets go.
library;

import 'dart:async';

import 'package:diktafon/data/db/database.dart';
import 'package:diktafon/data/repositories/cassette_repository.dart';
import 'package:diktafon/data/repositories/memo_repository.dart';
import 'package:diktafon/data/repositories/settings_repository.dart';
import 'package:diktafon/domain/models.dart';
import 'package:diktafon/services/processing/job_queue.dart';
import 'package:diktafon/services/providers/transcription_provider.dart'
    show ModelStatus;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job_queue_test.dart'
    show FakeSummarizationProvider, FakeTranscriptionProvider;

/// Records the calls a real Android service would receive, and refuses to
/// pretend they can overlap.
class FakeKeepAlive implements ProcessingKeepAlive {
  final calls = <String>[];
  bool held = false;

  /// Every acquire/release the queue asked for, in order.
  int get acquires => calls.where((c) => c == 'acquire').length;
  int get releases => calls.where((c) => c == 'release').length;

  @override
  Future<void> acquire() async {
    expect(held, isFalse, reason: 'acquire while already held');
    held = true;
    calls.add('acquire');
  }

  @override
  Future<void> release() async {
    expect(held, isTrue, reason: 'release without a matching acquire');
    held = false;
    calls.add('release');
  }
}

void main() {
  late AppDatabase db;
  late MemoRepository memos;
  late CassetteRepository cassettes;
  late SettingsRepository settings;
  late FakeTranscriptionProvider engine;
  late FakeSummarizationProvider llm;
  late FakeKeepAlive keepAlive;
  late JobQueue queue;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    memos = MemoRepository(db);
    cassettes = CassetteRepository(db);
    settings = SettingsRepository(db);
    engine = FakeTranscriptionProvider();
    llm = FakeSummarizationProvider();
    keepAlive = FakeKeepAlive();
    queue = JobQueue(db, memos, cassettes, settings, () => engine, () => llm,
        keepAlive: keepAlive, retryDelayUnit: Duration.zero);
    await db.into(db.cassettes).insert(CassetteRow(
          id: 'c1',
          titleIsUserSet: false,
          colorSeed: 1,
          createdAt: 0,
          updatedAt: 0,
        ));
  });

  tearDown(() => db.close());

  var seeded = 0;
  Future<Memo> seedMemo(String id) async {
    final memo = Memo(
      id: id,
      cassetteId: 'c1',
      filePath: '/audio/c1/$id.m4a',
      durationMs: 4000,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000 + seeded++),
      status: MemoStatus.stored,
    );
    await memos.insert(memo);
    return memo;
  }

  test('held from record-stop until the queue runs dry', () async {
    await seedMemo('m1');
    engine.gate = Completer<void>();

    await queue.enqueueTranscription('m1');
    await pumpEventQueue();

    // Held while whisper is mid-pass — the point of the whole exercise.
    expect(keepAlive.held, isTrue);

    engine.gate!.complete();
    await queue.drain();
    await pumpEventQueue();

    expect(keepAlive.held, isFalse);
    expect(keepAlive.calls, ['acquire', 'release']);
  });

  test('a drain with nothing to do never asks for the foreground', () async {
    // The launch drain: reconciliations run, no job is picked. A notification
    // flashing on every cold start would be a bug of its own.
    await queue.drain();
    await pumpEventQueue();

    expect(keepAlive.calls, isEmpty);
  });

  test('released even when the job cannot run', () async {
    // Model gone: the transcription is queued behind a closed gate and the
    // drain returns with the work still undone. Holding the service for a
    // job that will not run until the user acts is a battery leak.
    engine.status = ModelStatus.notInstalled;
    await seedMemo('m1');

    await queue.enqueueTranscription('m1');
    await queue.drain();
    await pumpEventQueue();

    expect(keepAlive.held, isFalse);
    expect(keepAlive.calls, ['acquire', 'release']);
    // The job itself is untouched — it goes when the model comes back.
    expect(await db.select(db.jobs).get(), hasLength(1));
  });

  test('one hold spans a whole backlog, not one per job', () async {
    for (final id in ['m1', 'm2', 'm3']) {
      await seedMemo(id);
      await queue.enqueueTranscription(id);
    }
    await queue.drain();
    await pumpEventQueue();

    expect(engine.calls, 3);
    expect(keepAlive.acquires, 1);
    expect(keepAlive.releases, 1);
  });

  test('dispose lets go of a hold the drain never got to drop', () async {
    // A queue outliving its app must not leave a notification standing.
    await seedMemo('m1');
    engine.gate = Completer<void>();
    await queue.enqueueTranscription('m1');
    await pumpEventQueue();
    expect(keepAlive.held, isTrue);

    queue.dispose();
    await pumpEventQueue();
    expect(keepAlive.held, isFalse);

    // Let the gated job unwind before the DB closes under it.
    engine.gate!.complete();
    await queue.drain();
    await pumpEventQueue();
  });

  test('no keep-alive wired is not a broken queue', () async {
    // Every platform but Android, and every test that predates this.
    final bare = JobQueue(db, memos, cassettes, settings, () => engine,
        () => llm,
        retryDelayUnit: Duration.zero);
    addTearDown(bare.dispose);
    await seedMemo('m1');

    await bare.enqueueTranscription('m1');
    await bare.drain();

    expect(engine.calls, 1);
  });
}
