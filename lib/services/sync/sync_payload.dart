/// The JSON one memo travels with (fork addition, laptop sync).
///
/// Shape is deliberately the export's (§8) `cassette.json`, sliced to a
/// single memo: same field names, same value encodings. The receiver
/// therefore reassembles a directory that is byte-for-byte the layout an
/// export would have produced, and `diktafon-pull`'s consumers keep their
/// bearings.
///
/// Rendering stays here, in the app's language: the receiver never
/// translates anything, it only fills `{n}` and `{date}` into the templates
/// this payload carries.
library;

import '../../domain/models.dart';
import '../export/cassette_exporter.dart';

const int syncFormatVersion = 1;

/// Sentinels round-tripped through the localized heading/note builders to
/// recover their `{n}`/`{date}` templates. They only have to be strings no
/// translation would ever contain — the substitution happens immediately,
/// on the app's own output, and never leaves this function.
const _nSentinel = 902138;
const _dateSentinel = '␀DATE␀';

String memoHeadingTemplate(ExportLabels labels) =>
    labels
        .memoHeading(_nSentinel, _dateSentinel)
        .replaceAll('$_nSentinel', '{n}')
        .replaceAll(_dateSentinel, '{date}');

String exportedNoteTemplate(ExportLabels labels) =>
    labels.exportedNote(_dateSentinel).replaceAll(_dateSentinel, '{date}');

/// Everything about one memo the receiver needs to file it and to rebuild
/// `transcript.md` and `cassette.json` around it.
Map<String, Object?> buildMemoPayload({
  required Cassette cassette,
  required Memo memo,
  required ExportLabels labels,
  required String audioExtension,
  required int? audioBytes,
  required String? audioSha256,
}) =>
    {
      'syncVersion': syncFormatVersion,
      'formatVersion': CassetteExporter.manifestVersion,
      'cassette': {
        'id': cassette.id,
        'label': cassette.label,
        'titleIsUserSet': cassette.titleIsUserSet,
        'colorSeed': cassette.colorSeed,
        'summary': cassette.summary,
        'summaryUpdatedAt': cassette.summaryUpdatedAt?.toIso8601String(),
        'createdAt': cassette.createdAt.toIso8601String(),
        'updatedAt': cassette.updatedAt.toIso8601String(),
      },
      'memo': {
        'id': memo.id,
        'createdAt': memo.createdAt.toIso8601String(),
        'durationMs': memo.durationMs,
        'language': memo.detectedLang,
        'summary': memo.memoSummary,
        'transcript': memo.transcript?.toJson(),
      },
      // The localized shell of the markdown the receiver assembles.
      'render': {
        'untitled': labels.untitled,
        'summaryHeading': labels.summaryHeading,
        'headingTemplate': memoHeadingTemplate(labels),
        'noteTemplate': exportedNoteTemplate(labels),
        'stamp': CassetteExporter.stamp(memo.createdAt),
        'body': CassetteExporter(labels: labels).memoSectionBody(memo),
      },
      'audio': audioBytes == null
          ? null
          : {
              'ext': audioExtension,
              'bytes': audioBytes,
              'sha256': audioSha256,
            },
    };
