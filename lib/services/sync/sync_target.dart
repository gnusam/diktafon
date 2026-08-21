/// Where the laptop receiver lives (fork addition).
///
/// The user pastes **one** string, printed by the receiver at startup:
///
///     https://sam:secret@diktafon.tunnel.olibrio.fr#tok_9f3c…
///
/// Everything the client needs is in it: the base address, the tunnel's
/// basic-auth credentials, and — optionally — a shared token. The token
/// travels in the fragment on purpose: a fragment is never sent over the
/// wire, so it cannot end up in the reverse proxy's access log the way a
/// token in the path would; the client moves it into a header instead.
library;

import 'dart:convert';

class SyncTarget {
  const SyncTarget({required this.base, this.userInfo, this.token});

  /// Scheme + host + optional base path, without credentials or fragment.
  final Uri base;

  /// `user:password` for HTTP basic auth, or null when the endpoint is open
  /// (a receiver reached over the LAN, or a plain local dev run).
  final String? userInfo;

  /// Shared secret the receiver may require, sent as `X-Diktafon-Token`.
  final String? token;

  /// Parses the pasted string. Returns null for anything that could not be
  /// a usable target — the Settings row shows that as "not understood"
  /// rather than failing later, invisibly, inside a background job.
  static SyncTarget? parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;

    // A trailing slash in the pasted base must not become `//v1/memo`.
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return SyncTarget(
      base: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: path,
      ),
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      token: uri.fragment.isEmpty ? null : uri.fragment,
    );
  }

  /// `Uri.replace` percent-encodes anything in `path`, so a query has to be
  /// passed as parameters rather than glued onto the string.
  Uri endpoint(String path, {Map<String, String>? query}) => base.replace(
        path: '${base.path}/$path',
        queryParameters: query,
      );

  /// The `Authorization` header value, or null when there are no credentials.
  String? get basicAuthHeader => userInfo == null
      ? null
      : 'Basic ${base64Encode(utf8.encode(userInfo!))}';

  /// What the UI shows back once a target is understood — never the
  /// password, which the user pasted but should not have to see again.
  String get displayName => base.host + (base.path.isEmpty ? '' : base.path);
}
