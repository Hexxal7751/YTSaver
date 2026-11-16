import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// A part of a video to keep.
class TrimRange {
  const TrimRange(this.start, this.end);
  final Duration start;
  final Duration end;
  Duration get length => end - start;
}

/// Per-video options chosen in the "Extras" card.
class Extras {
  bool trimOn = false;
  Duration trimStart = Duration.zero;
  Duration trimEnd = Duration.zero;
  bool thumbnail = false;
  bool tags = true; // embed title/artist/cover in audio files
  ClosedCaptionTrackInfo? subtitle;

  /// The trim to apply, or null when it is off or covers the whole video.
  TrimRange? trimFor(Duration? total) {
    if (!trimOn) return null;
    if (trimEnd <= trimStart) return null;
    if (total != null && trimStart <= Duration.zero && trimEnd >= total) {
      return null;
    }
    return TrimRange(trimStart, trimEnd);
  }
}

/// "90" -> 1:30, "1:30", "1:02:03". Returns null if it is not a time.
Duration? parseTimeInput(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final parts = t.split(':');
  if (parts.length > 3) return null;
  var secs = 0.0;
  for (final p in parts) {
    final n = double.tryParse(p.trim());
    if (n == null || n < 0) return null;
    secs = secs * 60 + n;
  }
  return Duration(milliseconds: (secs * 1000).round());
}

/// 1m20s or 1h02m03s (safe for file names).
String compactTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}m${s}s';
  return '${m}m${s}s';
}

// ---------------------------------------------------------------- chapters

class Chapter {
  Chapter(this.start, this.title);
  final Duration start;
  final String title;
}

/// Finds chapter timestamps in a video description ("0:00 Intro").
/// YouTube chapters must start at 0:00, so anything else is ignored.
List<Chapter> parseChapters(String description) {
  final re = RegExp(
    r'^\s*(?:[-•·▪►▶>*]\s*)?\(?((?:\d{1,2}:)?\d{1,2}:\d{2})\)?\s*[-–—:|]?\s*(.+?)\s*$',
    multiLine: true,
  );
  final found = <Chapter>[];
  for (final m in re.allMatches(description)) {
    final t = parseTimeInput(m.group(1)!);
    final title = (m.group(2) ?? '').trim();
    if (t == null || title.isEmpty) continue;
    found.add(Chapter(t, title));
  }
  if (found.length < 2 || found.first.start != Duration.zero) return const [];
  for (var i = 1; i < found.length; i++) {
    if (found[i].start <= found[i - 1].start) return const [];
  }
  return found;
}

// --------------------------------------------------------------- subtitles

class Cue {
  Cue(this.start, this.end, this.text);
  final Duration start;
  final Duration end;
  final String text;
}

String _decode(String s) {
  var r = s;
  for (var i = 0; i < 2; i++) {
    r = r
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(RegExp(r'&#(\d+);'),
            (m) => String.fromCharCode(int.parse(m.group(1)!)))
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
            (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
        .replaceAll('&amp;', '&');
  }
  return r;
}

String _clean(String raw) {
  final noTags = raw.replaceAll(RegExp(r'<[^>]*>'), '');
  return _decode(noTags).replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();
}

Duration _ms(num ms) => Duration(milliseconds: ms.round());

/// Parses YouTube's XML captions (srv1 "<text start dur>" or srv3 "<p t d>").
List<Cue> parseCaptions(String xml) {
  final cues = <Cue>[];

  final a = RegExp(
    r'<text\s+start="([\d.]+)"(?:\s+dur="([\d.]+)")?[^>]*>(.*?)</text>',
    dotAll: true,
  );
  for (final m in a.allMatches(xml)) {
    final s = double.tryParse(m.group(1)!) ?? 0;
    final d = double.tryParse(m.group(2) ?? '') ?? 2.0;
    final text = _clean(m.group(3) ?? '');
    if (text.isEmpty) continue;
    cues.add(Cue(_ms(s * 1000), _ms((s + d) * 1000), text));
  }
  if (cues.isNotEmpty) return cues;

  final b = RegExp(
    r'<p\s+t="(\d+)"(?:\s+d="(\d+)")?[^>]*>(.*?)</p>',
    dotAll: true,
  );
  for (final m in b.allMatches(xml)) {
    final s = int.tryParse(m.group(1)!) ?? 0;
    final d = int.tryParse(m.group(2) ?? '') ?? 2000;
    final text = _clean(m.group(3) ?? '');
    if (text.isEmpty) continue;
    cues.add(Cue(_ms(s), _ms(s + d), text));
  }
  return cues;
}

String _ts(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)},$ms';
}

/// SubRip text. With [from]/[to] only that part is kept, shifted to 0:00.
String buildSrt(List<Cue> cues, {Duration? from, Duration? to}) {
  final out = StringBuffer();
  var n = 1;
  final offset = from ?? Duration.zero;
  for (final c in cues) {
    var s = c.start;
    var e = c.end;
    if (from != null) {
      if (e <= from) continue;
      s = s - offset;
      if (s < Duration.zero) s = Duration.zero;
      e = e - offset;
    }
    if (to != null) {
      final limit = to - offset;
      if (s >= limit) continue;
      if (e > limit) e = limit;
    }
    out.writeln(n++);
    out.writeln('${_ts(s)} --> ${_ts(e)}');
    out.writeln(c.text);
    out.writeln();
  }
  return out.toString();
}