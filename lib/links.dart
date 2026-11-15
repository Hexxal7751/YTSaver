final _idRe = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool looksLikeYoutube(String s) =>
    RegExp(r'(youtube\.com|youtu\.be)/', caseSensitive: false).hasMatch(s);

Uri? _parse(String input) {
  final s = input.replaceAll(RegExp(r'\s'), '');
  return Uri.tryParse(s.contains('://') ? s : 'https://$s');
}

/// Pulls the first YouTube link out of shared text such as
/// "Cool video https://youtu.be/abc123def45".
String? extractYoutubeLink(String text) {
  for (final m in RegExp(r'https?://\S+').allMatches(text)) {
    final u = m.group(0)!;
    if (looksLikeYoutube(u)) return u;
  }
  return looksLikeYoutube(text) ? text.trim() : null;
}

/// Playlist ID from a link (null if none, or if it is an auto-generated Mix).
String? extractPlaylistId(String input) {
  final uri = _parse(input);
  final id = uri?.queryParameters['list'];
  if (id == null || id.isEmpty || id.startsWith('RD')) return null;
  return id;
}

/// True for links that point at a playlist itself (no single video chosen).
bool isPlaylistOnlyLink(String input) {
  final uri = _parse(input);
  if (uri == null) return false;
  if (uri.host.toLowerCase() == 'youtu.be') return false;
  final segs = uri.pathSegments;
  if (segs.isNotEmpty && const {'shorts', 'live', 'embed'}.contains(segs.first)) {
    return false;
  }
  return segs.contains('playlist') || !uri.queryParameters.containsKey('v');
}

/// Turns any YouTube link (watch, youtu.be, shorts, live, embed, mobile,
/// music) or a bare video ID into a plain video ID.
String normalizeYoutubeInput(String input) {
  final s = input.replaceAll(RegExp(r'\s'), '');
  if (_idRe.hasMatch(s)) return s;
  final uri = Uri.tryParse(s.contains('://') ? s : 'https://$s');
  if (uri == null) return s;
  final segs = uri.pathSegments;
  if (uri.host.toLowerCase() == 'youtu.be' && segs.isNotEmpty) {
    return segs.first;
  }
  if (segs.length >= 2 &&
      const {'shorts', 'live', 'embed', 'v'}.contains(segs.first)) {
    return segs[1];
  }
  return uri.queryParameters['v'] ?? s;
}