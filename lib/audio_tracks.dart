import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// All streams of one audio language track (highest bitrate first).
class AudioTrackGroup {
  AudioTrackGroup(this.name, this.rank, this.streams);
  final String name;
  final int rank; // 3 = original, 2 = marked default, 1 = unknown, 0 = dubbed
  final List<AudioOnlyStreamInfo> streams;
}

/// How likely a stream is to be the original-language audio.
int _rank(AudioOnlyStreamInfo s) {
  final t = s.audioTrack;
  if (t == null) return 3; // video has a single audio track
  String xtags = '';
  try {
    xtags = (s.url.queryParameters['xtags'] ?? '').toLowerCase();
  } catch (_) {}
  if (xtags.contains('acont=original')) return 3;
  if (xtags.contains('acont=dubbed')) return 0;
  if (t.displayName.toLowerCase().contains('original')) return 3;
  try {
    final d = (t as dynamic).audioIsDefault;
    if (d is bool) return d ? 2 : 1;
  } catch (_) {}
  return 1;
}

bool isOriginalTrack(AudioOnlyStreamInfo s) => _rank(s) >= 2;

/// Groups the manifest's audio streams by language track (manifest order).
List<AudioTrackGroup> groupTracks(StreamManifest m) {
  final byName = <String, List<AudioOnlyStreamInfo>>{};
  for (final s in m.audioOnly) {
    byName.putIfAbsent(s.audioTrack?.displayName ?? '', () => []).add(s);
  }
  return [
    for (final e in byName.entries)
      AudioTrackGroup(
        e.key,
        _rank(e.value.first),
        [...e.value]..sort(
            (x, y) => y.bitrate.bitsPerSecond.compareTo(x.bitrate.bitsPerSecond)),
      ),
  ];
}

/// The original/default track (first one wins on ties).
AudioTrackGroup? defaultTrack(List<AudioTrackGroup> groups) {
  AudioTrackGroup? best;
  for (final g in groups) {
    if (best == null || g.rank > best.rank) best = g;
  }
  return best;
}