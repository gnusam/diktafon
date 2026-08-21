/// The HTTP side of the laptop sync (fork addition).
///
/// Deliberately `dart:io` and nothing else: the upstream app ships no HTTP
/// client and this is not a reason to add one. Two calls — a `ping` for the
/// Settings "test" button, and the memo upload the job queue drives.
///
/// The request always carries a `Content-Length`: the receiver is a stdlib
/// Python server, which does not decode chunked bodies. Sizes are known up
/// front (manifest bytes + the audio file's length), so this costs nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'sync_target.dart';

/// A failed exchange with the receiver. [permanent] marks the failures no
/// retry can fix (bad credentials, a payload the receiver refuses): the job
/// queue keeps retrying everything else forever, because "laptop is off" is
/// the normal case, not an error.
class SyncException implements Exception {
  SyncException(this.message, {this.statusCode, this.permanent = false});

  final String message;
  final int? statusCode;
  final bool permanent;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode — $message';
}

class LaptopSync {
  LaptopSync({
    HttpClient Function()? clientFactory,
    this.pingTimeout = const Duration(seconds: 12),
    this.uploadTimeout = const Duration(minutes: 4),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration pingTimeout;
  final Duration uploadTimeout;

  /// Returns the receiver's host name — what the Settings row shows so the
  /// user sees *which* machine answered, not just that something did.
  Future<String> ping(SyncTarget target) async {
    final body = await _send(
      target,
      'v1/ping',
      method: 'GET',
      timeout: pingTimeout,
    );
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final host = (json['host'] as String?)?.trim();
      if (host == null || host.isEmpty) throw const FormatException('no host');
      return host;
    } on FormatException {
      // Something answered, but it is not a Diktafon receiver — a proxy
      // error page, a captive portal, the wrong host entirely.
      throw SyncException('unexpected answer', permanent: true);
    }
  }

  /// Sends one memo: its manifest, and its audio when the file is there. A
  /// memo whose audio vanished still syncs — the transcript is the part
  /// that matters for a bug report.
  Future<void> uploadMemo(
    SyncTarget target, {
    required Map<String, Object?> manifest,
    File? audio,
    String audioFieldName = 'audio.m4a',
  }) async {
    final boundary =
        '----diktafon${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final manifestBytes = utf8.encode(jsonEncode(manifest));

    final head = utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="manifest"; filename="manifest.json"\r\n'
        'Content-Type: application/json; charset=utf-8\r\n\r\n');
    final audioHead = audio == null
        ? const <int>[]
        : utf8.encode('\r\n--$boundary\r\n'
            'Content-Disposition: form-data; name="audio"; filename="$audioFieldName"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final audioLength = audio == null ? 0 : await audio.length();

    await _send(
      target,
      'v1/memo',
      method: 'POST',
      timeout: uploadTimeout,
      contentType: 'multipart/form-data; boundary=$boundary',
      contentLength: head.length +
          manifestBytes.length +
          audioHead.length +
          audioLength +
          tail.length,
      writeBody: (request) async {
        request.add(head);
        request.add(manifestBytes);
        if (audio != null) {
          request.add(audioHead);
          await request.addStream(audio.openRead());
        }
        request.add(tail);
      },
    );
  }

  Future<String> _send(
    SyncTarget target,
    String path, {
    required String method,
    required Duration timeout,
    String? contentType,
    int? contentLength,
    Future<void> Function(HttpClientRequest request)? writeBody,
  }) async {
    final client = _clientFactory()..connectionTimeout = pingTimeout;
    try {
      final uri = target.endpoint(path);
      final request = await client.openUrl(method, uri).timeout(timeout);
      // A redirect on a POST would silently drop the body; treat any 3xx as
      // a misconfigured target instead.
      request.followRedirects = false;
      request.persistentConnection = false;
      final auth = target.basicAuthHeader;
      if (auth != null) request.headers.set(HttpHeaders.authorizationHeader, auth);
      if (target.token != null) {
        request.headers.set('X-Diktafon-Token', target.token!);
      }
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (contentLength != null) request.contentLength = contentLength;
      if (writeBody != null) await writeBody(request);

      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout)
          .catchError((_) => '');
      if (response.statusCode >= 200 && response.statusCode < 300) return body;

      // 401/403: wrong credentials or token — retrying cannot help, and a
      // silent forever-retry against a tunnel that rejects us is exactly
      // the failure the user must be told about.
      final permanent = response.statusCode == 401 ||
          response.statusCode == 403 ||
          (response.statusCode >= 400 && response.statusCode < 500 &&
              response.statusCode != 408 &&
              response.statusCode != 429);
      throw SyncException(
        _firstLine(body),
        statusCode: response.statusCode,
        permanent: permanent,
      );
    } on SyncException {
      rethrow;
    } on TimeoutException {
      throw SyncException('timed out');
    } on SocketException catch (e) {
      // The everyday case: laptop asleep, on battery, or off the network.
      throw SyncException(e.osError?.message ?? 'unreachable');
    } on HandshakeException catch (e) {
      throw SyncException('TLS: ${_firstLine(e.message)}');
    } on HttpException catch (e) {
      throw SyncException(_firstLine(e.message));
    } finally {
      client.close(force: true);
    }
  }

  static String _firstLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'refused';
    final line = trimmed.split('\n').first.trim();
    return line.length > 200 ? '${line.substring(0, 200)}…' : line;
  }
}

/// SHA-256 of a file, streamed — a long memo can be tens of megabytes and
/// has no business being held in memory just to be hashed.
Future<String> fileSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
