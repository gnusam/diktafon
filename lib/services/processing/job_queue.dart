import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/database.dart';
import '../../data/repositories/cassette_repository.dart';
import '../../data/repositories/mappers.dart';
import '../../data/repositories/memo_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models.dart';
import '../providers/llm/summary_prompts.dart' show estimateTokens;
import '../audio/audio_transcoder.dart';
import '../export/cassette_exporter.dart';
import '../providers/summarization_provider.dart';
import '../providers/transcription_provider.dart';
import '../sync/laptop_sync.dart';
import '../sync/sync_payload.dart';
import '../sync/sync_target.dart';
import 'chinese_script.dart';

/// The §6.5 job types. The cassette overview is always rebuilt from *all*
/// memo digests (§6.7 revised 2026-07-08), so `recomputeCassetteSummary` and
/// `updateCassetteSummary` run the same code — it stays, like
/// `cleanupTranscript` (the retired §6.8 LLM cleanup stage, now routed
/// straight to the gist), only so job rows persisted by older builds keep
/// draining.
enum JobType {
  transcribe,
  cleanupTranscript,
  summarizeMemo,
  updateCassetteSummary,
  recomputeCassetteSummary,
  transcodeAudio,
  uploadMemo;

  /// Enrichment stages whose failure marks the memo `failed` (§14).
  /// `transcodeAudio` deliberately stays out: a WAV that never becomes AAC
  /// is bigger, not broken — the memo plays either way, so its status must
  /// never suffer for a codec hiccup.
  bool get targetsMemo =>
      this == transcribe || this == cleanupTranscript || this == summarizeMemo;

  /// Fork addition (laptop sync): a stage whose failure is almost always
  /// "the other end isn't listening yet" — a laptop on battery, asleep, or
  /// simply elsewhere. Giving up after five tries would silently lose the
  /// memo the user recorded *because* they wanted it on the laptop, so this
  /// one retries for as long as it takes, parked between attempts.
  bool get retriesForever => this == uploadMemo;
}

/// §6.7 (revised 2026-07-28): only transcripts estimated *longer* than this
/// many tokens get a memo gist — anything shorter is its own summary, so the
/// LLM pass would only restate it (and burn battery). The cassette overview
/// reads the transcript directly for gistless memos. Counted in tokens, not
/// chars: 350 Han chars carry 2–3× the content of 350 Latin chars, so the
/// old 350-char gate was script-biased; 117 ≈ 350/3 keeps Latin behaviour.
const int gistTokenThreshold = 117;

/// Fork addition — the OS handle that keeps this process alive while the
/// queue works.
///
/// Durability was never the problem: jobs survive a kill. *Progress* was.
/// A backgrounded Android app is a cached app, and the OS freezes a cached
/// app's threads within seconds — so a memo recorded and left behind stopped
/// mid-whisper and never reached the laptop, however patient the queue was.
/// Holding a foreground service for exactly as long as a job is in hand is
/// what buys the drain the right to run at all.
///
/// A class-shaped seam, like [AudioTranscoder] and [LaptopSync]: tests get a
/// counter, and every platform but Android gets nothing (iOS suspends the
/// process whatever we do; desktop never pauses).
abstract class ProcessingKeepAlive {
  Future<void> acquire();
  Future<void> release();

  /// Where whisper is, for the handle's own display (the Android
  /// notification): a fraction 0..1 while a memo is on the engine, null
  /// once it is off. Only ever called between [acquire] and [release].
  Future<void> report(double? fraction) async {}
}

/// What the transcription engine is doing right now: which memo, on which
/// cassette, and how far through its audio it has got ([fraction] 0..1, the
/// engine's own figure — see [TranscriptionProvider.transcribe]). The
/// queue publishes one of these while a memo is on the engine and null in
/// between, so the transcript can draw a bar under the memo and the home
/// grid can say which tape is busy.
class TranscriptionProgress {
  const TranscriptionProgress({
    required this.memoId,
    required this.cassetteId,
    required this.fraction,
  });

  final String memoId;
  final String cassetteId;
  final double fraction;
}

/// Durable background pipeline (§6.5): jobs persist in the DB so they survive
/// restarts; ML concurrency is 1 to bound CPU/thermals/battery.
///
/// Providers are resolved through getters on every use so a Settings tier
/// switch takes effect without rebuilding the queue (rebuilding could let two
/// queues drain the same jobs).
class JobQueue {
  JobQueue(this._db, this._memos, this._cassettes, this._settings,
      this._transcription, this._summarization,
      {this._transcoder,
      this._sync,
      this._keepAlive,
      this._inferenceAllowed,
      this._exportLabels = _defaultExportLabels,
      this._retryDelayUnit = const Duration(seconds: 1),
      this._systemZhScript = _defaultZhScript});

  final AppDatabase _db;
  final MemoRepository _memos;
  final CassetteRepository _cassettes;
  final SettingsRepository _settings;
  final TranscriptionProvider Function() _transcription;
  final SummarizationProvider Function() _summarization;

  /// §6.4: encodes finished WAV captures to the archival AAC. Null (tests
  /// that predate it) keeps transcode jobs parked in the queue.
  final AudioTranscoder Function()? _transcoder;

  /// Fork addition: the laptop receiver client. Null (tests that predate
  /// it) keeps upload jobs parked in the queue, exactly like a missing
  /// transcoder does.
  final LaptopSync Function()? _sync;

  /// Fork addition: kept pinned while a job is in hand, dropped the moment
  /// the queue idles. Null off Android (and in tests that predate it), where
  /// the queue simply runs unprotected as it always did.
  final ProcessingKeepAlive? _keepAlive;

  /// Fork addition — the battery gate. Whisper and the LLM are the two
  /// stages that genuinely cost a phone; below the threshold on battery
  /// they hold. Read fresh on every pass of the loop, like the model and
  /// settings gates beside it, so a charger plugged in mid-backlog releases
  /// the *next* job rather than interrupting the one running.
  ///
  /// Deliberately not applied to `uploadMemo`: a finished memo reaching the
  /// laptop is a few hundred kilobytes, and holding that back on low
  /// battery would recreate exactly the symptom this fork exists to remove.
  /// Null (tests, every platform but Android) → always open.
  final bool Function()? _inferenceAllowed;

  /// The strings a synced memo's markdown is rendered with — resolved from
  /// the system locale, because jobs run with no widget tree to ask.
  final ExportLabels Function() _exportLabels;

  static ExportLabels _defaultExportLabels() => const ExportLabels();

  /// D8 amendment: the script an auto-detected `zh` memo is stored in —
  /// production wires the system locale; tests inject.
  final String Function() _systemZhScript;

  static String _defaultZhScript() => 'Hans';

  /// Backoff = attempts × this; tests inject zero.
  final Duration _retryDelayUnit;

  /// How far back the automatic sync reaches for memos nothing ever sent.
  static const _sweepWindow = Duration(days: 7);
  final _uuid = const Uuid();

  /// In-flight cancellation handles, by memo id (§14 delete-during-processing).
  final Map<String, CancelToken> _active = {};

  /// Where the engine is, for anyone watching (see [TranscriptionProgress]).
  /// Broadcast, so several screens can listen; the current value is kept
  /// beside it so a late subscriber does not wait for the next window.
  final _progress = StreamController<TranscriptionProgress?>.broadcast();
  TranscriptionProgress? _currentProgress;

  /// The memo whisper is on and how far it has got — null while the engine
  /// is idle. Opens with the current state, so a cassette opened mid-memo
  /// shows the bar at once rather than at the next report.
  Stream<TranscriptionProgress?> watchTranscriptionProgress() async* {
    yield _currentProgress;
    yield* _progress.stream;
  }

  void _reportProgress(TranscriptionProgress? progress) {
    _currentProgress = progress;
    if (!_progress.isClosed) _progress.add(progress);
    // The keep-alive's notification is the one place the user sees this
    // from another app. Same chain as acquire/release, so a report can
    // never overtake the acquire it belongs to or trail the release.
    final keepAlive = _keepAlive;
    if (keepAlive == null || !_pinned) return;
    final fraction = progress?.fraction;
    _keepAliveOps = _keepAliveOps
        .then((_) => _pinned ? keepAlive.report(fraction) : null)
        .catchError((_) {});
  }


  Future<void>? _draining;
  Timer? _wake;
  bool _recoveredOrphans = false;
  static const _maxAttempts = 5;

  /// Whether the keep-alive is currently held, and the chain that serializes
  /// acquire/release across the platform channel — flipping the flag is
  /// synchronous so a release can never overtake the acquire it undoes.
  bool _pinned = false;
  Future<void> _keepAliveOps = Future<void>.value();

  void _setPinned(bool wanted) {
    if (_keepAlive == null || _pinned == wanted) return;
    _pinned = wanted;
    _keepAliveOps = _keepAliveOps
        .then((_) => wanted ? _keepAlive.acquire() : _keepAlive.release())
        // A keep-alive that fails is a queue that runs unprotected, never a
        // queue that stops.
        .catchError((_) {});
  }

  /// Enqueued on record-stop (D7).
  ///
  /// Pinned here rather than in the drain: at record-stop the app is still
  /// foreground, which is the only moment Android reliably lets a service
  /// start — and stop-then-swipe-away is precisely the gesture this fixes.
  /// The drain drops the pin when it finds nothing left to do.
  Future<void> enqueueTranscription(String memoId) async {
    await _insertJob(JobType.transcribe, memoId);
    // Before the drain, not inside it: by the time the loop reaches its
    // first job the app may already be away, and Android only lets a
    // *foreground* app raise a service. Here we are still on the turn that
    // handled the stop button. (After the insert, so a failed write can't
    // strand a hold nothing will release.)
    _setPinned(true);
    unawaited(drain());
  }

  /// Enqueued on record-stop, after the transcription (§6.4): the WAV
  /// capture becomes the archival AAC in the background — the memo plays
  /// either form, so nothing waits on this.
  Future<void> enqueueTranscode(String memoId) async {
    await _insertJob(JobType.transcodeAudio, memoId);
    unawaited(drain());
  }

  /// Fork addition — laptop sync (opt-in). Queues whatever has not reached
  /// the laptop: the whole library, one cassette, on demand. [force] also
  /// re-sends memos already acknowledged (the receiver is idempotent by
  /// memo id) and wakes jobs parked in their backoff — that is what the
  /// user means by tapping "send" a second time.
  Future<void> enqueueUploads({String? cassetteId, bool force = false}) async {
    if (_sync == null) return;
    if (!(await _settings.get()).syncConfigured) return;
    // Successive `where`s AND together — the tape order is what makes a
    // bulk send arrive in the order it was recorded.
    final query = _db.select(_db.memos)
      ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]);
    if (!force) query.where((m) => m.syncedAt.isNull());
    if (cassetteId != null) {
      query.where((m) => m.cassetteId.equals(cassetteId));
    }
    for (final row in await query.get()) {
      await _insertUploadJob(row.id, force: force);
    }
    unawaited(drain());
  }

  /// Count for the Settings row ("send N pending memos"): memos the laptop
  /// has never acknowledged. Zero is the steady state once sync is on.
  Stream<int> watchPendingUploads() {
    final count = _db.memos.id.count();
    return (_db.selectOnly(_db.memos)
          ..addColumns([count])
          ..where(_db.memos.syncedAt.isNull()))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  /// Count for the battery-gate row in Settings: enrichment jobs still
  /// queued. Reads the jobs, not the memo statuses — a memo waiting on a
  /// shut gate keeps its honest `stored`, and only the job knows there is
  /// work outstanding for it.
  Stream<int> watchPendingEnrichment() {
    final count = _db.jobs.id.count();
    return (_db.selectOnly(_db.jobs)
          ..addColumns([count])
          ..where(_db.jobs.status.equals('queued') &
              _db.jobs.type.isIn(
                  [JobType.transcribe.name, JobType.summarizeMemo.name])))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  /// The automatic path: called wherever a memo reaches its final content.
  /// Silent unless sync is both configured *and* set to send by itself.
  Future<void> _maybeEnqueueUpload(String memoId) async {
    if (_sync == null) return;
    final settings = await _settings.get();
    if (!settings.syncConfigured || !settings.syncAuto) return;
    await _insertUploadJob(memoId);
    unawaited(drain());
  }

  /// One upload job per memo at a time. An existing one is reused rather
  /// than duplicated; [force] pulls it out of its backoff so an explicit
  /// send retries now instead of in a quarter of an hour.
  Future<void> _insertUploadJob(String memoId, {bool force = false}) async {
    final existing = await (_db.select(_db.jobs)
          ..where((j) =>
              j.targetId.equals(memoId) &
              j.type.equals(JobType.uploadMemo.name)))
        .get();
    final live =
        existing.where((j) => j.status == 'queued' || j.status == 'running');
    if (live.isNotEmpty) {
      if (!force) return;
      for (final job in live) {
        await (_db.update(_db.jobs)..where((j) => j.id.equals(job.id)))
            .write(const JobsCompanion(
                attempts: Value(0), nextAttemptAt: Value(null)));
      }
      return;
    }
    // A row that gave up permanently (bad credentials, refused payload) is
    // replaced, not kept alongside the new attempt.
    for (final job in existing) {
      await (_db.delete(_db.jobs)..where((j) => j.id.equals(job.id))).go();
    }
    await _insertJob(JobType.uploadMemo, memoId);
  }

  Future<bool> _hasPendingTranscode(String memoId) async =>
      (await (_db.select(_db.jobs)
                ..where((j) =>
                    j.targetId.equals(memoId) &
                    j.type.equals(JobType.transcodeAudio.name) &
                    j.status.isIn(['queued', 'running'])))
              .get())
          .isNotEmpty;

  /// Failed memo → back on the queue at the right stage (§14 retry
  /// affordance): no transcript yet → transcribe again, otherwise only the
  /// summarization is redone.
  Future<void> retryEnrichment(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null) return;
    if (row.transcript == null) {
      await _memos.updateStatus(memoId, MemoStatus.stored);
      await _insertJob(JobType.transcribe, memoId);
    } else {
      await _memos.updateStatus(memoId, MemoStatus.transcribed);
      await _insertJob(JobType.summarizeMemo, memoId);
    }
    unawaited(drain());
  }

  /// Manual transcript edit (§6.9): the corrected text replaces the engine's
  /// take and re-enters the pipeline at the summary stage — the old gist
  /// described the old words, so it is cleared rather than left to lie. Long
  /// transcripts queue a fresh gist (which schedules the overview rebuild
  /// itself); short ones are their own summary (§6.7), so only the overview
  /// needs refreshing. The memo's queued jobs are dropped first — they would
  /// re-derive stale artifacts from the replaced text.
  Future<void> applyTranscriptEdit(String memoId, Transcript transcript) async {
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)
    await cancelJobsFor(memoId);
    final wantsGist = _wantsGist(transcript);
    // Atomic pair, like retranscribe: a kill between the write and the
    // enqueue must not strand the memo without its follow-up job.
    await _db.transaction(() async {
      await _memos.setEditedTranscript(memoId, transcript,
          wantsGist ? MemoStatus.transcribed : MemoStatus.ready);
      // What the laptop holds describes the old words: the memo counts as
      // unsent again (the gist path re-sends after its own stage).
      await _memos.clearSynced(memoId);
      if (wantsGist) {
        await _insertJob(JobType.summarizeMemo, memoId);
      } else {
        await _enqueueCassetteUpdate(row.cassetteId);
      }
    });
    if (!wantsGist) await _maybeEnqueueUpload(memoId);
    unawaited(drain());
  }

  /// Re-runs the whole enrichment pipeline for every memo on the cassette —
  /// the user installed a more capable model and wants the texts refreshed.
  /// In-flight and queued work is cancelled, transcripts and gists wiped,
  /// and fresh transcribe jobs queued in tape order. The overview follows
  /// for free: each new gist schedules the coalesced cassette update, and
  /// the old overview stays visible until it's replaced.
  Future<void> retranscribeCassette(String cassetteId) async {
    // A queued overview rebuild would see the wiped gists and blank the
    // summary early — drop it; the new gists schedule their own.
    await cancelJobsFor(cassetteId);
    for (final memo in await _memos.memosOf(cassetteId)) {
      await cancelJobsFor(memo.id);
      // Atomic pair: a kill between the wipe and the enqueue would strand
      // the memo at `stored` with no job and no §14 retry affordance.
      await _db.transaction(() async {
        await _memos.resetEnrichment(memo.id);
        await _insertJob(JobType.transcribe, memo.id);
      });
    }
    unawaited(drain());
  }

  /// Cancels queued *and in-flight* work for a cassette about to be deleted
  /// (§14): every memo's jobs plus the cassette-level summary jobs. Without
  /// this an in-flight transcription keeps burning CPU for minutes after the
  /// delete, then retries its decode against the removed audio file.
  Future<void> cancelCassetteJobs(String cassetteId) async {
    for (final memo in await _memos.memosOf(cassetteId)) {
      await cancelJobsFor(memo.id);
    }
    await cancelJobsFor(cassetteId);
  }

  /// Cancels pending *and in-flight* work for a deleted memo (§14).
  Future<void> cancelJobsFor(String targetId) async {
    _active[targetId]?.cancel();
    await (_db.delete(_db.jobs)
          ..where(
              (j) => j.targetId.equals(targetId) & j.status.equals('queued')))
        .go();
  }

  /// Call after a memo's row is gone: if its gist — or, for gistless memos,
  /// its transcript (§6.7) — was part of the cassette summary, schedule the
  /// rebuild (§14 "cassette summary is scheduled to update").
  Future<void> onMemoDeleted(Memo memo) async {
    final contributed =
        memo.memoSummary != null || !(memo.transcript?.isEmpty ?? true);
    if (!contributed) return;
    await _enqueueCassetteUpdate(memo.cassetteId);
    unawaited(drain());
  }

  /// Processes queued jobs sequentially. Called on app start (resume after
  /// restart), after every enqueue, when a model finishes downloading, and
  /// when summaries are re-enabled. Awaiting joins the drain already in
  /// flight, if any.
  Future<void> drain() => _draining ??= _drainLoop().whenComplete(() {
        _draining = null;
        // However the loop ended — idle queue, or a throw — the process has
        // no further claim on being foreground.
        _setPinned(false);
      });

  Future<void> _drainLoop() async {
    if (!_recoveredOrphans) {
      _recoveredOrphans = true;
      await _recoverOrphans();
      await _reconcileStrandedMemos();
      await _reconcileStrandedWavs();
      // Done rows written by pre-pruning builds are pure archaeology —
      // completed jobs are deleted outright now (see _run), so sweep the
      // legacy ones too instead of scanning them on every drain forever.
      await (_db.delete(_db.jobs)..where((j) => j.status.equals('done'))).go();
      await _sweepUnsynced();
    }
    // Upload jobs parked in this pass: their next slot is minutes away, and
    // re-picking them would spin the loop instead of letting the rest of
    // the queue through.
    final parked = <String>{};
    // One failed upload is enough to know the laptop is not listening: the
    // drain is sequential, and walking a backlog of ten memos into ten
    // connection timeouts would hold up the transcription of the next
    // recording for minutes. They all keep their places in the queue.
    var laptopSilent = false;
    while (true) {
      // Enrichment waits for a provisioned model (§14) — and summarization
      // additionally for the summaries switch (the model picker's "No
      // summaries" row); blocked jobs stay queued. Re-checked every
      // iteration: models/settings can change mid-drain.
      final settings = await _settings.get();
      final llmReady =
          await _summarization().modelStatus() == ModelStatus.ready;
      // The battery gate, re-read here with the rest: a charger plugged in
      // mid-drain opens it on the next pass, no restart, no gesture.
      final powered = _inferenceAllowed?.call() ?? true;
      final runnable = <String>[];
      if (powered &&
          await _transcription().modelStatus() == ModelStatus.ready) {
        runnable.add(JobType.transcribe.name);
      }
      // Legacy cleanup rows only hand over to the gist — no LLM involved,
      // so they are always runnable.
      runnable.add(JobType.cleanupTranscript.name);
      // Transcoding needs no model, only a wired platform encoder.
      if (_transcoder != null) runnable.add(JobType.transcodeAudio.name);
      if (powered && settings.summariesEnabled && llmReady) {
        runnable.addAll([
          JobType.summarizeMemo.name,
          JobType.updateCassetteSummary.name,
          JobType.recomputeCassetteSummary.name,
        ]);
      }
      // Uploading needs a wired client and a configured target; without
      // either, the rows wait (nothing is lost — the memos keep their null
      // `syncedAt` and go up the day sync is set up).
      if (_sync != null && settings.syncConfigured && !laptopSilent) {
        runnable.add(JobType.uploadMemo.name);
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final job = await (_db.select(_db.jobs)
            ..where((j) {
              var where = j.status.equals('queued') &
                  j.type.isIn(runnable) &
                  (j.nextAttemptAt.isNull() |
                      j.nextAttemptAt.isSmallerOrEqualValue(now));
              if (parked.isNotEmpty) {
                where = where & j.id.isNotIn(parked.toList());
              }
              return where;
            })
            ..orderBy([
              // Fork: a memo that is ready to leave leaves before the next
              // whisper pass begins. An upload is seconds and never gated;
              // a transcription is minutes and may be held for hours by
              // the battery gate — and a queue of them is exactly what a
              // long session leaves behind. FIFO put the finished memo's
              // trip to the laptop behind every one of them, so "done
              // transcribing" and "on the laptop" drifted hours apart.
              (j) => OrderingTerm.desc(j.type.equals(JobType.uploadMemo.name)),
              (j) => OrderingTerm.asc(j.createdAt),
            ])
            ..limit(1))
          .getSingleOrNull();
      if (job == null) {
        await _scheduleWake();
        return;
      }
      // Work in hand: hold the process foreground for as long as it lasts.
      // A no-op when the record-stop path already pinned; the one that
      // matters is a drain that started from a wake or a launch.
      _setPinned(true);
      await _run(job);
      if (JobType.values.byName(job.type).retriesForever) {
        parked.add(job.id);
        // A job that went through is deleted; one still on the table did
        // not — so the rest of the backlog can wait for the next wake.
        laptopSilent = await (_db.select(_db.jobs)
                  ..where((j) => j.id.equals(job.id)))
                .getSingleOrNull() !=
            null;
      }
    }
  }

  /// Nothing is runnable *now*, but a parked upload may become runnable
  /// later: wake the drain when the earliest one comes due, so a memo goes
  /// up as soon as the laptop is reachable again — no user gesture, no app
  /// restart. Only ever one timer, always for the nearest deadline.
  Future<void> _scheduleWake() async {
    _wake?.cancel();
    _wake = null;
    if (_sync == null) return;
    final next = _db.jobs.nextAttemptAt.min();
    final row = await (_db.selectOnly(_db.jobs)
          ..addColumns([next])
          ..where(_db.jobs.status.equals('queued') &
              _db.jobs.nextAttemptAt.isNotNull()))
        .getSingleOrNull();
    final at = row?.read(next);
    if (at == null) return;
    final delay = at - DateTime.now().millisecondsSinceEpoch;
    if (delay <= 0) return; // due already: the next drain picks it up
    _wake = Timer(Duration(milliseconds: delay), () {
      _wake = null;
      unawaited(drain());
    });
  }

  /// Memos that never reached the laptop and have no job to take them
  /// there: orphaned by a kill between the enrichment and the enqueue, or
  /// recorded in the days before sync was set up. Runs once per process,
  /// like the other reconciliations, and only when sync sends by itself.
  ///
  /// Bounded to [_sweepWindow] on purpose: switching sync on must not push
  /// a year of recordings up a mobile connection unasked. Anything older
  /// goes when the user says so — the Settings row and the cassette menu
  /// both send without a window.
  Future<void> _sweepUnsynced() async {
    if (_sync == null) return;
    final settings = await _settings.get();
    if (!settings.syncConfigured || !settings.syncAuto) return;
    final since =
        DateTime.now().subtract(_sweepWindow).millisecondsSinceEpoch;
    final rows = await (_db.select(_db.memos)
          ..where((m) =>
              m.syncedAt.isNull() & m.createdAt.isBiggerOrEqualValue(since))
          ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
        .get();
    // A memo still waiting for whisper is not lost, only not written up:
    // its own pipeline files the trip when the transcript lands. Sending
    // it now would carry it up half-made and again when done — and since
    // uploads outrank whisper in the drain, "now" would come first.
    final live = await (_db.select(_db.jobs)
          ..where((j) =>
              j.type.equals(JobType.transcribe.name) &
              j.status.isIn(['queued', 'running'])))
        .get();
    final awaitingTranscript = {for (final job in live) job.targetId};
    for (final row in rows) {
      if (awaitingTranscript.contains(row.id)) continue;
      await _insertUploadJob(row.id);
    }
  }

  /// Stops the wake-up timer and closes the progress stream — a queue
  /// outliving its app (tests, a disposed provider) must keep neither a
  /// timer alive nor listeners waiting.
  void dispose() {
    _wake?.cancel();
    _wake = null;
    _setPinned(false);
    _progress.close();
  }

  Future<void> _run(JobRow job) async {
    final type = JobType.values.byName(job.type);
    await _setJob(job.id, 'running', attempts: job.attempts + 1);
    try {
      switch (type) {
        case JobType.transcribe:
          await _transcribe(job.targetId);
        case JobType.cleanupTranscript:
          await _legacyCleanupPassthrough(job.targetId);
        case JobType.summarizeMemo:
          await _summarizeMemo(job.targetId);
        case JobType.updateCassetteSummary:
        case JobType.recomputeCassetteSummary:
          await _updateCassetteSummary(job.targetId);
        case JobType.transcodeAudio:
          await _transcodeAudio(job.targetId);
        case JobType.uploadMemo:
          await _uploadMemo(job.targetId);
      }
      // Completed jobs are deleted, not archived: nothing reads them back,
      // and years of use would otherwise leave thousands of dead rows under
      // every drain query (the jobs table has no index on status).
      await (_db.delete(_db.jobs)..where((j) => j.id.equals(job.id))).go();
    } on TranscriptionCancelled {
      // Memo deleted while transcribing — the job is moot, not failed.
      await (_db.delete(_db.jobs)..where((j) => j.id.equals(job.id))).go();
    } catch (error) {
      final attempts = job.attempts + 1;
      // A refused upload (wrong credentials, receiver saying no) is the one
      // way this stage gives up: retrying a rejection forever would hide it.
      final refused = error is SyncException && error.permanent;
      final permanent =
          refused || (attempts >= _maxAttempts && !type.retriesForever);
      await _setJob(job.id, permanent ? 'failed' : 'queued',
          attempts: attempts,
          // Park the retry instead of sleeping on it: the drain is
          // sequential, and a memo waiting on an absent laptop must not
          // hold up the transcription of the next one.
          nextAttemptAt: permanent || !type.retriesForever
              ? null
              : DateTime.now().millisecondsSinceEpoch +
                  (_retryDelayUnit * _uploadBackoffUnits(attempts)).inMilliseconds);
      if (permanent) {
        // Memo stays playable; a retry affordance is offered (§14). Cassette
        // jobs leave no failed memo — their digests stay unfolded and ride
        // along with the next successful update.
        if (type.targetsMemo) {
          await _memos.updateStatus(job.targetId, MemoStatus.failed);
        }
      } else {
        // The requeued job may park behind a closed drain gate (model
        // deleted, tier switched to a not-yet-downloaded one) — reset the
        // memo to its honest waiting status so the "transcribing…" shimmer
        // never outlives the stage that showed it; the rerun re-asserts it.
        if (type.targetsMemo) await _resetToWaiting(job.targetId);
        // Brief backoff so transient failures don't hot-loop (§6.5).
        // Parked stages already carry their delay in `nextAttemptAt`.
        if (!type.retriesForever) {
          await Future<void>.delayed(_retryDelayUnit * attempts);
        }
      }
    }
  }

  /// Puts a memo back to the waiting status its enrichment stage starts
  /// from — `stored` before a transcript exists, `transcribed` after.
  Future<void> _resetToWaiting(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)
    await _memos.updateStatus(
        memoId,
        row.transcript == null ? MemoStatus.stored : MemoStatus.transcribed);
  }

  /// A job stays 'running' in the DB for the length of its stage — if the
  /// process dies meanwhile (Android freely kills backgrounded apps, and
  /// transcription is minutes of heavy CPU with no foreground service), the
  /// row is orphaned: the drain only picks 'queued', so the job would never
  /// run again and its memo would show "transcribing…" forever. Once per
  /// process, before the first drain, every 'running' row is therefore a
  /// leftover of a dead run (ML concurrency is 1 and this instance hasn't
  /// started anything yet): requeue it and put its memo back to the honest
  /// waiting status — the stage re-asserts the in-flight one when it reruns.
  /// The interrupted run already counted its attempt, so an input that kills
  /// the engine natively exhausts [_maxAttempts] across launches instead of
  /// crash-looping the app forever.
  Future<void> _recoverOrphans() async {
    final orphans = await (_db.select(_db.jobs)
          ..where((j) => j.status.equals('running')))
        .get();
    for (final job in orphans) {
      final permanent = job.attempts >= _maxAttempts;
      await _setJob(job.id, permanent ? 'failed' : 'queued');
      if (!JobType.values.byName(job.type).targetsMemo) continue;
      if (permanent) {
        await _memos.updateStatus(job.targetId, MemoStatus.failed);
      } else {
        await _resetToWaiting(job.targetId);
      }
    }
  }

  /// The other way an enrichment chain breaks (§6.5): a memo stranded in a
  /// waiting/in-flight status with *no* job at all — the process died
  /// between the memo insert and its enqueue (record stop, import), or
  /// between a wipe and its re-enqueue (pre-transaction retranscribe).
  /// Nothing would ever pick it up: it renders as "queued for
  /// transcription" forever and, not being `failed`, offers no retry.
  /// Re-enter the pipeline at the right stage, like [retryEnrichment].
  Future<void> _reconcileStrandedMemos() async {
    // Memos first, jobs second — the order is the whole correctness argument.
    // A record-stop lands the memo row and its job as two separate writes,
    // and this sweep runs on the launch drain, so the two can interleave.
    // Reading jobs first let a memo inserted in between look job-less and
    // earn a *second* transcribe job: the same recording through whisper
    // twice. This way round the worst case is a memo too young to be in the
    // snapshot, which is exactly the memo whose own enqueue is already on
    // its way.
    final rows = await (_db.select(_db.memos)
          ..where((m) => m.status.isIn([
                MemoStatus.stored.name,
                MemoStatus.transcribing.name,
                MemoStatus.transcribed.name,
                MemoStatus.summarizing.name,
              ])))
        .get();
    final live = await (_db.select(_db.jobs)
          ..where((j) => j.status.isIn(['queued', 'running'])))
        .get();
    final covered = {for (final job in live) job.targetId};
    for (final row in rows) {
      if (covered.contains(row.id)) continue;
      if (row.transcript == null) {
        await _memos.updateStatus(row.id, MemoStatus.stored);
        await _insertJob(JobType.transcribe, row.id);
      } else {
        await _memos.updateStatus(row.id, MemoStatus.transcribed);
        await _insertJob(JobType.summarizeMemo, row.id);
      }
    }
  }

  /// A memo still on its WAV capture with no transcode row anywhere — the
  /// process died between the memo insert and the enqueue, or the row was
  /// recovered by an older build. One fresh job puts it back on track;
  /// `failed` rows count as covered so a permanently hopeless encode doesn't
  /// re-enter on every launch (the WAV plays fine as it is).
  Future<void> _reconcileStrandedWavs() async {
    if (_transcoder == null) return;
    final covered = {
      for (final job in await (_db.select(_db.jobs)
            ..where((j) => j.type.equals(JobType.transcodeAudio.name)))
          .get())
        job.targetId,
    };
    final rows = await (_db.select(_db.memos)
          ..where((m) => m.filePath.like('%.wav')))
        .get();
    for (final row in rows) {
      if (covered.contains(row.id)) continue;
      await _insertJob(JobType.transcodeAudio, row.id);
    }
  }

  /// §6.4: WAV capture → archival AAC, then the memo row is swapped over
  /// and the WAV deleted. Idempotent and self-cancelling: a memo already on
  /// AAC, gone, or missing its audio simply completes the job.
  Future<void> _transcodeAudio(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)
    final wavPath = row.filePath;
    if (!wavPath.endsWith('.wav')) return; // already archival
    if (!File(wavPath).existsSync()) return; // missing audio (§14)

    final outPath = '${wavPath.substring(0, wavPath.length - 4)}.m4a';
    await _transcoder!().transcode(wavPath, outPath);
    final out = File(outPath);
    if (!out.existsSync() || out.lengthSync() == 0) {
      throw StateError('transcode produced no output');
    }
    if (await _memoRow(memoId) == null) {
      // Deleted mid-encode — drop the output; the WAV went with the memo.
      try {
        out.deleteSync();
      } catch (_) {}
      return;
    }
    await _memos.updateFilePath(memoId, outPath);
    // The archival file is what should travel; an upload that deferred to
    // this encode (or one queued before it) now has its .m4a.
    await _maybeEnqueueUpload(memoId);
    try {
      File(wavPath).deleteSync();
    } catch (_) {
      // A busy/vanished WAV is orphan-sweep food, not a failure.
    }
  }

  /// Fork addition — laptop sync. One memo goes up: its manifest (the
  /// export's own shape, sliced to a single memo) and its audio. Only a 2xx
  /// stamps `syncedAt`; anything else throws and the job parks for another
  /// go. Everything here is idempotent on the receiver's side, so a
  /// re-send after a half-finished upload is safe by construction.
  Future<void> _uploadMemo(String memoId) async {
    final sync = _sync;
    if (sync == null) return; // not wired (older tests)
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)
    final target = SyncTarget.parse((await _settings.get()).syncUrl);
    if (target == null) return; // sync switched off while queued

    // Still on its WAV capture with the encode right behind us: let the
    // archival AAC be what travels — the transcode re-enqueues this job.
    if (row.filePath.endsWith('.wav') && await _hasPendingTranscode(memoId)) {
      return;
    }

    final cassetteRow = await (_db.select(_db.cassettes)
          ..where((c) => c.id.equals(row.cassetteId)))
        .getSingleOrNull();
    if (cassetteRow == null) return; // cassette deleted meanwhile (§14)

    final audio = File(row.filePath);
    // A memo whose audio vanished (metadata-only restore, §8) still syncs:
    // the transcript is the part a bug report is made of.
    final present = audio.existsSync();
    final dot = row.filePath.lastIndexOf('.');
    final ext = dot > row.filePath.lastIndexOf('/')
        ? row.filePath.substring(dot)
        : '.m4a';

    await sync().uploadMemo(
      target,
      manifest: buildMemoPayload(
        cassette: cassetteFromRow(cassetteRow),
        memo: memoFromRow(row),
        labels: _exportLabels(),
        audioExtension: ext,
        audioBytes: present ? await audio.length() : null,
        audioSha256: present ? await fileSha256(audio) : null,
      ),
      audio: present ? audio : null,
      audioFieldName: '${row.id}$ext',
    );
    await _memos.markSynced(memoId, DateTime.now());
  }

  Future<void> _transcribe(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)

    final cancel = CancelToken();
    _active[memoId] = cancel;
    try {
      await _memos.updateStatus(memoId, MemoStatus.transcribing);
      final settings = await _settings.get();
      // "On it, nothing to report yet" — the decode and any VAD pass come
      // before the engine's first figure; the memo shows its shimmer for
      // exactly that long.
      TranscriptionProgress at(double fraction) => TranscriptionProgress(
          memoId: memoId, cassetteId: row.cassetteId, fraction: fraction);
      _reportProgress(at(0));
      final raw = await _transcription().transcribe(
        AudioRef(row.filePath),
        languageCode: settings.appLanguage,
        cancel: cancel,
        onProgress: (fraction) => _reportProgress(at(fraction)),
      );
      // D8 amendment: Chinese transcripts are stored script-converted under
      // a script-qualified code (forced zh-Hans/zh-Hant, or the system
      // locale's script for an auto-detected zh); everything else is
      // untouched.
      final transcript = resolveChineseScript(
        raw,
        appLanguage: settings.appLanguage,
        systemZhScript: _systemZhScript,
      );

      if (transcript.isEmpty) {
        // Empty/near-silent memo: kept playable, summary skipped (§14, §6.7)
        // — nothing left to enrich.
        await _memos.setTranscript(memoId, transcript, MemoStatus.ready);
        await _maybeEnqueueUpload(memoId);
      } else if (!_wantsGist(transcript)) {
        // Short transcript (§6.7): it is its own summary — the memo is done
        // without ever touching the LLM; only the overview job (which reads
        // the transcript directly) waits on the summarization gate.
        await _memos.setTranscript(memoId, transcript, MemoStatus.ready);
        await _enqueueCassetteUpdate(row.cassetteId);
        await _maybeEnqueueUpload(memoId);
      } else {
        await _memos.setTranscript(memoId, transcript, MemoStatus.transcribed);
        // The gist job waits in the queue while its model is missing or
        // summaries are disabled — the drain gate holds it, never the memo.
        await _insertJob(JobType.summarizeMemo, memoId);
      }
    } finally {
      _active.remove(memoId);
      // Done, failed or cancelled alike: the engine is free.
      _reportProgress(null);
    }
  }

  /// A cleanup row persisted by a pre-removal build (§6.8, retired
  /// 2026-07-13: the phase-0 bench showed LLM cleanup is accuracy-inert at
  /// ~1.2× the ASR's runtime): hand the memo to the gist stage unchanged.
  Future<void> _legacyCleanupPassthrough(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null || row.transcript == null) return;
    await _insertJob(JobType.summarizeMemo, memoId);
  }

  Future<void> _summarizeMemo(String memoId) async {
    final row = await _memoRow(memoId);
    if (row == null) return; // deleted meanwhile (§14)
    final transcriptJson = row.transcript;
    if (transcriptJson == null) return; // can't happen; be safe

    final transcript = await transcriptsFromJsonAsync([transcriptJson])
        .then((list) => list.first!);
    if (transcript.isEmpty) {
      // Nothing to summarize (§6.7) — reachable via retryEnrichment on a
      // silent memo; complete the enrichment instead of prompting the LLM.
      await _memos.setMemoSummary(memoId, null, MemoStatus.ready);
      await _maybeEnqueueUpload(memoId);
      return;
    }
    if (!_wantsGist(transcript)) {
      // Short transcript (§6.7) — reachable via retryEnrichment or a job
      // persisted by an older build: complete without the LLM; the overview
      // reads the transcript directly.
      await _memos.setMemoSummary(memoId, null, MemoStatus.ready);
      await _enqueueCassetteUpdate(row.cassetteId);
      await _maybeEnqueueUpload(memoId);
      return;
    }
    await _memos.updateStatus(memoId, MemoStatus.summarizing);

    final language = await _languageFor(row.detectedLang);
    // matchChineseScript is belt-and-braces (D8): the prompt pins
    // Simplified/Traditional, but small models drift.
    final summary = matchChineseScript(
        (await _summarization()
                .summarizeMemo(transcript, languageCode: language))
            .trim(),
        language);

    // An empty gist (model produced nothing usable) is recorded as "no
    // summary", not a failure — the memo is still fully enriched (§6.7).
    // The overview updates either way: gistless memos contribute their
    // transcript.
    await _memos.setMemoSummary(
        memoId, summary.isEmpty ? null : summary, MemoStatus.ready);
    await _enqueueCassetteUpdate(row.cassetteId);
    // The memo is final now — gist included — so this is where it earns its
    // trip to the laptop.
    await _maybeEnqueueUpload(memoId);
  }

  /// §6.7: short transcripts are their own summary — no gist.
  bool _wantsGist(Transcript t) =>
      estimateTokens(t.plainText) > gistTokenThreshold;

  /// Rebuilds the overview from *all* memo digests, in tape order (§6.7
  /// revised): the gist where one exists, the (short) transcript itself
  /// where none does. Always faithful to the tape's current content —
  /// additions and deletions alike — at the cost of re-reading every
  /// digest (bounded by the prompt's char budget).
  Future<void> _updateCassetteSummary(String cassetteId) async {
    final cassette = await (_db.select(_db.cassettes)
          ..where((c) => c.id.equals(cassetteId)))
        .getSingleOrNull();
    if (cassette == null) return; // deleted meanwhile (§14)

    final rows = await (_db.select(_db.memos)
          ..where((m) =>
              m.cassetteId.equals(cassetteId) &
              (m.memoSummary.isNotNull() | m.transcript.isNotNull()))
          ..orderBy([
            (m) => OrderingTerm.asc(m.createdAt),
            (m) => OrderingTerm.asc(m.id),
          ]))
        .get();
    final contributing = <(MemoRow, String)>[
      for (final row in rows)
        if (row.memoSummary ??
            await _transcriptText(row.transcript)
            case final text?)
          (row, text), // silent memos yield null and drop out
    ];
    if (contributing.isEmpty) {
      // The last contributing memo was deleted — the overview no longer
      // describes anything; the (possibly user-set) label stays.
      await _cassettes.setSummary(cassetteId, null);
      return;
    }

    final language = await _languageFor(contributing.first.$1.detectedLang);
    final summary = matchChineseScript(
        (await _summarization().updateCassetteSummary(
          previousSummary: null,
          newMemos: [
            for (final (row, text) in contributing)
              MemoDigest(
                memoSummary: text,
                createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
              ),
          ],
          languageCode: language,
        ))
            .trim(),
        language);
    if (summary.isEmpty) return;

    await _cassettes.setSummary(cassetteId, summary);

    // D10 (revised): a title is suggested only while the label is blank —
    // effectively once, with the first overview; after that the name stays
    // put until the user renames.
    if (cassette.label == null && !cassette.titleIsUserSet) {
      final title = matchChineseScript(
          (await _summarization()
                  .suggestTitle(summary, languageCode: language))
              .trim(),
          language);
      if (title.isNotEmpty) {
        await _cassettes.setSuggestedLabel(cassetteId, title);
      }
    }
  }

  /// The digest text of a gistless memo (§6.7): its short transcript,
  /// flattened to one line; null when the memo is silent.
  Future<String?> _transcriptText(String? transcriptJson) async {
    if (transcriptJson == null) return null;
    final transcript =
        (await transcriptsFromJsonAsync([transcriptJson])).first!;
    if (transcript.isEmpty) return null;
    return transcript.plainText.replaceAll('\n', ' ');
  }

  /// D8: languages are per memo — an explicit Settings override wins (for
  /// speakers whisper keeps mis-detecting), otherwise the memo's own
  /// detection; 'en' only as the last resort.
  Future<String> _languageFor(String? detectedLang) async =>
      (await _settings.get()).appLanguage ?? detectedLang ?? 'en';

  /// Coalescing (§6.5 debounce): the rebuild reads the tape's state at run
  /// time, so one queued cassette job covers every gist (or deletion) that
  /// lands before it runs — bursts collapse into a single update.
  Future<void> _enqueueCassetteUpdate(String cassetteId) async {
    final queued = await (_db.select(_db.jobs)
          ..where((j) =>
              j.targetId.equals(cassetteId) &
              j.status.equals('queued') &
              j.type.isIn([
                JobType.updateCassetteSummary.name,
                JobType.recomputeCassetteSummary.name,
              ])))
        .get();
    if (queued.isNotEmpty) return;
    await _insertJob(JobType.updateCassetteSummary, cassetteId);
  }

  Future<MemoRow?> _memoRow(String memoId) =>
      (_db.select(_db.memos)..where((m) => m.id.equals(memoId)))
          .getSingleOrNull();

  Future<void> _insertJob(JobType type, String targetId) =>
      _db.into(_db.jobs).insert(JobRow(
            id: _uuid.v4(),
            type: type.name,
            targetId: targetId,
            status: 'queued',
            attempts: 0,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));

  Future<void> _setJob(String id, String status,
          {int? attempts, int? nextAttemptAt}) =>
      (_db.update(_db.jobs)..where((j) => j.id.equals(id))).write(JobsCompanion(
        status: Value(status),
        attempts: attempts == null ? const Value.absent() : Value(attempts),
        nextAttemptAt: Value(nextAttemptAt),
      ));

  /// 30 s, 60 s, 90 s … capped at a quarter of an hour (in units of
  /// [_retryDelayUnit], which tests set to zero).
  static int _uploadBackoffUnits(int attempts) =>
      attempts * 30 < 900 ? attempts * 30 : 900;
}
