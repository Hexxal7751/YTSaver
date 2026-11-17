import 'dart:convert';

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

const _kOpen = '[[ytsaver-chapters]]';
const _kClose = '[[/ytsaver-chapters]]';

String _clockOf(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0
      ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
      : '${d.inMinutes}:${two(d.inSeconds % 60)}';
}

/// A text block that [parseChapters] recognises first. Used to hand chapters
/// found on YouTube's page to the rest of the app through the description.
String chaptersToBlock(List<Chapter> list) =>
    '$_kOpen\n${list.map((c) => '${_clockOf(c.start)} ${c.title}').join('\n')}\n$_kClose\n';

final _hasLetter = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _validChapters(List<Chapter> l, Duration? total) {
  if (l.length < 2) return false;
  for (var i = 1; i < l.length; i++) {
    if (l[i].start <= l[i - 1].start) return false;
  }
  if (l.first.start != Duration.zero && l.length < 3) return false;
  if (total != null && l.last.start >= total) return false;
  return true;
}

List<Chapter> _scan(String text, {required bool timeFirst}) {
  final re = timeFirst
      ? RegExp(
          r'^[ \t]*(?:[^\w\s(\[]{1,4}[ \t]*)?[(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[)\]]?[ \t]*[-–—:|.]*[ \t]*(.+?)[ \t]*$',
          multiLine: true)
      : RegExp(
          r'^[ \t]*(.+?)[ \t]*[-–—:|(\[][ \t]*((?:\d{1,2}:)?\d{1,2}:\d{2})[)\]]?[ \t]*$',
          multiLine: true);
  final out = <Chapter>[];
  for (final m in re.allMatches(text)) {
    final timeStr = timeFirst ? m.group(1)! : m.group(2)!;
    var title = (timeFirst ? m.group(2) : m.group(1)) ?? '';
    title = title.replaceAll(RegExp(r'^[\s\-–—:|.]+|[\s\-–—:|.]+$'), '').trim();
    final t = parseTimeInput(timeStr);
    if (t == null || title.isEmpty || !_hasLetter.hasMatch(title)) continue;
    out.add(Chapter(t, title));
  }
  return out;
}

/// Finds chapters in a video description: "0:00 Intro" or "Intro - 0:00".
/// Also understands the block added by [chaptersToBlock].
List<Chapter> parseChapters(String description, {Duration? total}) {
  final open = description.indexOf(_kOpen);
  if (open >= 0) {
    final close = description.indexOf(_kClose, open);
    if (close > open) {
      final block = description.substring(open + _kOpen.length, close);
      final l = _scan(block, timeFirst: true);
      if (_validChapters(l, total)) return l;
    }
  }
  final text = description.replaceAll('\r', '');
  var found = _scan(text, timeFirst: true);
  if (!_validChapters(found, total)) found = _scan(text, timeFirst: false);
  return _validChapters(found, total) ? found : const <Chapter>[];
}

/// Reads chapters out of a YouTube watch page (creator or automatic ones).
List<Chapter> chaptersFromWatchHtml(String html, {Duration? total}) {
  String dec(String raw) {
    try {
      return jsonDecode('"$raw"') as String;
    } catch (_) {
      return raw;
    }
  }

  const title =
      r'\{(?:"simpleText":"((?:[^"\\]|\\.)*)"|"runs":\[\{"text":"((?:[^"\\]|\\.)*)"\}\])\}';
  final byStart = <int, String>{};

  final a = RegExp('"chapterRenderer":\\{"title":$title,"timeRangeStartMillis":(\\d+)');
  for (final m in a.allMatches(html)) {
    final t = dec(m.group(1) ?? m.group(2) ?? '').trim();
    final ms = int.tryParse(m.group(3) ?? '') ?? -1;
    if (ms >= 0 && t.isNotEmpty) byStart.putIfAbsent(ms, () => t);
  }

  if (byStart.length < 2) {
    final b = RegExp(
        '"macroMarkersListItemRenderer":\\{"title":$title,"timeDescription":\\{"simpleText":"([\\d:]+)"');
    for (final m in b.allMatches(html)) {
      final t = dec(m.group(1) ?? m.group(2) ?? '').trim();
      final d = parseTimeInput(m.group(3) ?? '');
      if (d != null && t.isNotEmpty) byStart.putIfAbsent(d.inMilliseconds, () => t);
    }
  }

  final keys = byStart.keys.toList()..sort();
  final list = [
    for (final k in keys) Chapter(Duration(milliseconds: k), byStart[k]!),
  ];
  return _validChapters(list, total) ? list : const <Chapter>[];
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