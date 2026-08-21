/// The one string the user pastes, and the markdown templates that ride
/// along with every memo (fork addition, laptop sync).
library;

import 'package:diktafon/domain/models.dart';
import 'package:diktafon/services/export/cassette_exporter.dart';
import 'package:diktafon/services/sync/sync_payload.dart';
import 'package:diktafon/services/sync/sync_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncTarget.parse', () {
    test('takes credentials, base path and token out of one paste', () {
      final target = SyncTarget.parse(
          'https://sam:secret@diktafon.tunnel.example.fr/base#tok_abc')!;
      expect(target.base.toString(), 'https://diktafon.tunnel.example.fr/base');
      expect(target.endpoint('v1/memo').toString(),
          'https://diktafon.tunnel.example.fr/base/v1/memo');
      expect(target.token, 'tok_abc');
      expect(target.basicAuthHeader, 'Basic ${'c2FtOnNlY3JldA=='}');
      // What the Settings row shows back: never the password.
      expect(target.displayName, 'diktafon.tunnel.example.fr/base');
    });

    test('a bare host works, and a trailing slash does not double up', () {
      final target = SyncTarget.parse('http://127.0.0.1:8099/')!;
      expect(target.endpoint('v1/ping').toString(),
          'http://127.0.0.1:8099/v1/ping');
      expect(target.token, isNull);
      expect(target.basicAuthHeader, isNull);
    });

    test('refuses what it cannot send to', () {
      expect(SyncTarget.parse(null), isNull);
      expect(SyncTarget.parse('   '), isNull);
      expect(SyncTarget.parse('diktafon.example.fr'), isNull,
          reason: 'no scheme — Uri reads the host as a path');
      expect(SyncTarget.parse('ftp://example.fr'), isNull);
      expect(SyncTarget.parse('https://'), isNull);
    });
  });

  group('payload templates', () {
    test('localized headings come back as {n}/{date} templates', () {
      const labels = ExportLabels();
      expect(memoHeadingTemplate(labels), 'Memo {n} — {date}');
      expect(exportedNoteTemplate(labels), 'Exported from Diktafon on {date}.');
    });

    test('a memo carries the export shape, sliced to one memo', () {
      final memo = Memo(
        id: 'm1',
        cassetteId: 'c1',
        filePath: '/audio/m1.m4a',
        durationMs: 4200,
        createdAt: DateTime(2026, 8, 20, 17, 40, 4),
        status: MemoStatus.ready,
        detectedLang: 'fr',
        memoSummary: 'un résumé',
        transcript: const Transcript(languageCode: 'fr', segments: [
          Segment(startMs: 0, endMs: 900, words: [
            Word(text: 'bonjour', startMs: 0, endMs: 900),
          ]),
        ]),
      );
      final payload = buildMemoPayload(
        cassette: Cassette(
          id: 'c1',
          label: 'life',
          titleIsUserSet: true,
          colorSeed: 7,
          summary: null,
          summaryUpdatedAt: null,
          createdAt: DateTime(2026, 8, 20),
          updatedAt: DateTime(2026, 8, 20),
        ),
        memo: memo,
        labels: const ExportLabels(),
        audioExtension: '.m4a',
        audioBytes: 4,
        audioSha256: 'deadbeef',
      );

      expect((payload['memo']! as Map)['id'], 'm1');
      expect((payload['memo']! as Map)['durationMs'], 4200);
      expect((payload['memo']! as Map)['transcript'], isNotNull);
      expect((payload['cassette']! as Map)['label'], 'life');
      expect((payload['audio']! as Map)['sha256'], 'deadbeef');
      final render = payload['render']! as Map;
      expect(render['stamp'], '2026-08-20 17:40');
      // Gist quote then transcript — the export's own section layout.
      expect(render['body'], '> un résumé\n\nbonjour');
    });

    test('a memo whose audio vanished still has a payload', () {
      final payload = buildMemoPayload(
        cassette: Cassette(
          id: 'c1',
          label: null,
          titleIsUserSet: false,
          colorSeed: 1,
          summary: null,
          summaryUpdatedAt: null,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        memo: Memo(
          id: 'm2',
          cassetteId: 'c1',
          filePath: '/gone.m4a',
          durationMs: 0,
          createdAt: DateTime(2026),
          status: MemoStatus.ready,
        ),
        labels: const ExportLabels(),
        audioExtension: '.m4a',
        audioBytes: null,
        audioSha256: null,
      );
      expect(payload['audio'], isNull);
      expect((payload['render']! as Map)['body'], '(not transcribed)');
    });
  });
}
