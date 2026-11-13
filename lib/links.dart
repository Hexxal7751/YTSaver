final _idRe = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool looksLikeYoutube(String s) =>
    RegExp(r'(youtube\.com|youtu\.be)/', caseSensitive: false).hasMatch(s);

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