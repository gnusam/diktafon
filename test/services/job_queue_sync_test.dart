/// Laptop sync (fork addition): the upload stage of the job queue, driven
/// against a real HTTP server on loopback — multipart framing, the
/// `Content-Length` the stdlib receiver needs, and the retry policy that
/// makes "the laptop is off" a wait rather than a failure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diktafon/data/db/database.dart';
import 'package:diktafon/data/repositories/cassette_repository.dart';
import 'package:diktafon/data/repositories/memo_repository.dart';
import 'package:diktafon/data/repositories/settings_repository.dart';
import 'package:diktafon/domain/models.dart';
import 'package:diktafon/services/audio/audio_transcoder.dart';
import 'package:diktafon/services/processing/job_queue.dart';
import 'package:diktafon/services/providers/transcription_provider.dart'
    show ModelStatus;
import 'package:diktafon/services/sync/laptop_sync.dart';
import 'package:diktafon/services/sync/sync_target.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job_queue_test.dart'
    show
        FakeSummarizationProvider,
        FakeTranscriptionProvider,
        shortTranscript;

/// One received upload, already taken apart.
class Received {
  Received(this.manifest, this.audio, this.headers);

  final Map<String, dynamic> manifest;
  final List<int>? audio;
  final HttpHeaders headers;

  Map<String, dynamic> get memo => manifest['memo'] as Map<String, dynamic>;
}

/// A receiver stand-in: parses exactly the multipart the client sends, and
/// can be told to refuse.
class StubReceiver {
  StubReceiver(this._server) {
    _server.listen(_handle);
  }

  static Future<StubReceiver> start() async =>
      StubReceiver(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final uploads = <Received>[];
  int pings = 0;
  int status = 200;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await _collect(request);
    if (request.uri.path.endsWith('/v1/ping')) {
      pings++;
      request.response
        ..statusCode = status
        ..write(jsonEncode({'host': 'test-laptop'}));
      await request.response.close();
      return;
    }
    if (status == 200) {
      uploads.add(_parse(request.headers, body));
    }
    request.response
      ..statusCode = status
      ..write(status == 200 ? '{"ok":true}' : 'nope');
    await request.response.close();
  }

  static Future<List<int>> _collect(HttpRequest request) async {
    final out = <int>[];
    await for (final chunk in request) {
      out.addAll(chunk);
    }
    return out;
  }

  static Received _parse(HttpHeaders headers, List<int> body) {
    final boundary = RegExp('boundary=(.+)')
        .firstMatch(headers.contentType!.parameters['boundary'] == null
            ? headers.value(HttpHeaders.contentTypeHeader)!
            : 'boundary=${headers.contentType!.parameters['boundary']}')!
        .group(1)!;
    final delim = utf8.encode('--$boundary');
    Map<String, dynamic>? manifest;
    List<int>? audio;

    var start = 0;
    final parts = <List<int>>[];
    while (true) {
      final at = _indexOf(body, delim, start);
      if (at < 0) break;
      if (start > 0) parts.add(body.sublist(start, at - 2)); // drop CRLF
      start = at + delim.length;
      if (start + 2 <= body.length &&
          body[start] == 0x2d &&
          body[start + 1] == 0x2d) {
        break; // closing boundary
      }
      start += 2; // CRLF after the boundary line
    }
    for (final part in parts) {
      final split = _indexOf(part, utf8.encode('\r\n\r\n'), 0);
      final head = utf8.decode(part.sublist(0, split));
      final content = part.sublist(split + 4);
      if (head.contains('name="manifest"')) {
        manifest = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      } else if (head.contains('name="audio"')) {
        audio = content;
      }
    }
    return Received(manifest!, audio, headers);
  }

  static int _indexOf(List<int> haystack, List<int> needle, int from) {
    for (var i = from; i <= haystack.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}

class FakeTranscoder implements AudioTranscoder {
  @override
  Future<void> transcode(String wavPath, String outPath) async =>
      File(outPath).writeAsBytesSync(const [0x41, 0x41, 0x43]);
}

void main() {
  late Directory work;
  late AppDatabase db;
  late MemoRepository memos;
  late CassetteRepository cassettes;
  late SettingsRepository settings;
  late FakeTranscriptionProvider engine;
  late StubReceiver receiver;
  late JobQueue queue;

  JobQueue buildQueue() => JobQueue(
        db,
        memos,
        cassettes,
        settings,
        () => engine,
        () => FakeSummarizationProvider(status: ModelStatus.notInstalled),
        transcoder: () => FakeTranscoder(),
        sync: LaptopSync.new,
        retryDelayUnit: Duration.zero,
      );

  setUp(() async {
    work = Directory.systemTemp.createTempSync('dk_sync_');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    memos = MemoRepository(db);
    cassettes = CassetteRepository(db);
    settings = SettingsRepository(db);
    engine = FakeTranscriptionProvider(
        result: shortTranscript('fr', 'bonjour le laptop'));
    receiver = await StubReceiver.start();
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
    queue = buildQueue();
  });

  tearDown(() async {
    queue.dispose();
    await receiver.close();
    await db.close();
    work.deleteSync(recursive: true);
  });

  Future<Memo> seedMemo(
      {String id = 'm1', String ext = '.m4a', DateTime? createdAt}) async {
    final file = File('${work.path}/$id$ext')..writeAsBytesSync([1, 2, 3, 4]);
    final memo = Memo(
      id: id,
      cassetteId: 'c1',
      filePath: file.path,
      durationMs: 4000,
      createdAt: createdAt ?? DateTime.now(),
      status: MemoStatus.stored,
    );
    await memos.insert(memo);
    return memo;
  }

  Future<MemoRow> memoRow(String id) =>
      (db.select(db.memos)..where((m) => m.id.equals(id))).getSingle();

  Future<List<JobRow>> uploadJobs() => (db.select(db.jobs)
        ..where((j) => j.type.equals(JobType.uploadMemo.name)))
      .get();

  test('an enriched memo goes up by itself, audio and all', () async {
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();

    expect(receiver.uploads, hasLength(1));
    final upload = receiver.uploads.single;
    expect(upload.memo['id'], 'm1');
    expect((upload.manifest['cassette'] as Map)['label'], 'life');
    expect(upload.audio, [1, 2, 3, 4]);
    // The receiver rebuilds markdown from these, so they must survive the trip.
    final render = upload.manifest['render'] as Map<String, dynamic>;
    expect(render['headingTemplate'], contains('{n}'));
    expect(render['headingTemplate'], contains('{date}'));
    expect(render['body'], contains('bonjour le laptop'));
    expect(upload.headers.contentLength, greaterThan(0),
        reason: 'the stdlib receiver cannot read a chunked body');

    expect((await memoRow('m1')).syncedAt, isNotNull);
    expect(await uploadJobs(), isEmpty, reason: 'done jobs are deleted');
  });

  test('automatic off: nothing leaves until an explicit send', () async {
    await settings.setSyncAuto(false);
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();
    expect(receiver.uploads, isEmpty);
    expect((await memoRow('m1')).syncedAt, isNull);

    await queue.enqueueUploads();
    await queue.drain();
    expect(receiver.uploads, hasLength(1));
  });

  test('no target configured: memos wait, no job is even created', () async {
    await settings.setSyncUrl(null);
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();
    expect(await uploadJobs(), isEmpty);
    expect((await memoRow('m1')).syncedAt, isNull);
  });

  test('an unreachable laptop is a wait, not a failure', () async {
    await receiver.close(); // the port stops answering
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();

    final job = (await uploadJobs()).single;
    expect(job.status, 'queued', reason: 'it must come back on its own');
    expect(job.attempts, 1);
    expect(job.nextAttemptAt, isNotNull, reason: 'parked, not slept on');
    final memo = await memoRow('m1');
    expect(memo.syncedAt, isNull);
    expect(memo.status, MemoStatus.ready.name,
        reason: 'the memo itself is fine — only its delivery is pending');
  });

  test('a refused upload gives up instead of retrying forever', () async {
    receiver.status = 401;
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();

    final job = (await uploadJobs()).single;
    expect(job.status, 'failed');
    expect(job.attempts, 1, reason: 'no point in a second rejection');
    expect((await memoRow('m1')).status, MemoStatus.ready.name);
  });

  test('a forced send re-uploads what the laptop already has', () async {
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();
    expect(receiver.uploads, hasLength(1));

    await queue.enqueueUploads(); // nothing pending
    await queue.drain();
    expect(receiver.uploads, hasLength(1));

    await queue.enqueueUploads(cassetteId: 'c1', force: true);
    await queue.drain();
    expect(receiver.uploads, hasLength(2));
    expect(receiver.uploads.last.memo['id'], 'm1');
  });

  test('the archival .m4a travels, never the raw capture', () async {
    await seedMemo(ext: '.wav');
    await queue.enqueueTranscription('m1');
    await queue.enqueueTranscode('m1');
    await queue.drain();

    expect(receiver.uploads, hasLength(1),
        reason: 'the upload deferred to the encode instead of sending twice');
    expect(receiver.uploads.single.audio, [0x41, 0x41, 0x43]);
    expect((await memoRow('m1')).filePath, endsWith('.m4a'));
  });

  test('an edited transcript is sent again', () async {
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();
    expect(receiver.uploads, hasLength(1));

    await queue.applyTranscriptEdit('m1', shortTranscript('fr', 'corrigé'));
    await queue.drain();
    expect(receiver.uploads, hasLength(2));
    expect(
        (receiver.uploads.last.manifest['render'] as Map)['body'], 'corrigé');
  });

  test('memos recorded before sync existed are swept up at launch', () async {
    await settings.setSyncAuto(false);
    await seedMemo();
    await queue.enqueueTranscription('m1');
    await queue.drain();
    expect(receiver.uploads, isEmpty);

    // Sync gets set up, and the app restarts: a fresh queue over the same
    // database finds the memo nothing ever sent.
    await settings.setSyncAuto(true);
    final fresh = buildQueue();
    addTearDown(fresh.dispose);
    await fresh.drain();
    expect(receiver.uploads, hasLength(1));
  });

  test('switching sync on does not push the whole back catalogue', () async {
    await settings.setSyncAuto(false);
    await seedMemo(
        id: 'old', createdAt: DateTime.now().subtract(const Duration(days: 400)));
    await queue.enqueueTranscription('old');
    await queue.drain();
    expect(receiver.uploads, isEmpty);

    // Sync goes on and the app restarts: the launch sweep reaches back a
    // week, so a year-old memo stays put…
    await settings.setSyncAuto(true);
    final fresh = buildQueue();
    addTearDown(fresh.dispose);
    await fresh.drain();
    expect(receiver.uploads, isEmpty);

    // …until it is asked for explicitly.
    await fresh.enqueueUploads();
    await fresh.drain();
    expect(receiver.uploads, hasLength(1));
  });

  test('ping names the machine that answered', () async {
    final host =
        await LaptopSync().ping(SyncTarget.parse(receiver.url)!);
    expect(host, 'test-laptop');
    expect(receiver.pings, 1);
  });

  test('a receiver that is not one is a permanent failure', () async {
    receiver.status = 500;
    await expectLater(
      LaptopSync().ping(SyncTarget.parse(receiver.url)!),
      throwsA(isA<SyncException>().having((e) => e.permanent, 'permanent', false)),
    );
  });
}
