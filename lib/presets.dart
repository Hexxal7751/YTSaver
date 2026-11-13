import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'download_manager.dart';
import 'settings.dart';

extension PresetInfo on QualityPreset {
  String get title => switch (this) {
        QualityPreset.best => 'Best quality',
        QualityPreset.p1080 => 'Full HD 1080p',
        QualityPreset.p720 => 'HD 720p',
        QualityPreset.smallest => 'Smallest size',
        QualityPreset.audio => 'Audio only',
      };

  IconData get icon => switch (this) {
        QualityPreset.best => Icons.auto_awesome,
        QualityPreset.p1080 => Icons.hd,
        QualityPreset.p720 => Icons.high_quality,
        QualityPreset.smallest => Icons.compress,
        QualityPreset.audio => Icons.music_note,
      };
}

class PresetPick {
  PresetPick(this.video, this.audio);
  final VideoOnlyStreamInfo? video;
  final AudioOnlyStreamInfo? audio;

  bool get valid => video != null || audio != null;
  int get bytes =>
      (video?.size.totalBytes ?? 0) + (audio?.size.totalBytes ?? 0);
}

String pickSummary(PresetPick p) {
  final parts = <String>[];
  final v = p.video;
  final a = p.audio;
  if (v != null) parts.add('${v.qualityLabel} ${vcodecName(v.videoCodec)}');
  if (a != null) {
    parts.add('${acodecName(a.audioCodec)} ${a.bitrate.kiloBitsPerSecond.round()}k');
  }
  return parts.join(' + ');
}

/// [videos] must be sorted best-first (height, fps, bitrate);
/// [audios] sorted by bitrate, highest first.
PresetPick pickPreset(
  QualityPreset p,
  List<VideoOnlyStreamInfo> videos,
  List<AudioOnlyStreamInfo> audios,
) {
  AudioOnlyStreamInfo? audioFor(VideoOnlyStreamInfo? v) {
    if (audios.isEmpty) return null;
    if (v != null && v.container.name == 'mp4') {
      final m = audios.where((a) => a.container.name == 'mp4');
      if (m.isNotEmpty) return m.first;
    }
    return audios.first;
  }

  VideoOnlyStreamInfo? bestUnder(int maxH) {
    final ok = videos.where((s) => s.videoResolution.height <= maxH).toList();
    if (ok.isEmpty) return videos.isEmpty ? null : videos.last;
    final h = ok.first.videoResolution.height;
    final sameH = ok.where((s) => s.videoResolution.height == h).toList();
    final mp4 = sameH.where((s) => s.container.name == 'mp4');
    return mp4.isNotEmpty ? mp4.first : sameH.first;
  }

  switch (p) {
    case QualityPreset.best:
      {
        final v = videos.firstOrNull;
        return PresetPick(v, audioFor(v));
      }
    case QualityPreset.p1080:
      {
        final v = bestUnder(1080);
        return PresetPick(v, audioFor(v));
      }
    case QualityPreset.p720:
      {
        final v = bestUnder(720);
        return PresetPick(v, audioFor(v));
      }
    case QualityPreset.smallest:
      {
        VideoOnlyStreamInfo? v;
        for (final s in videos) {
          if (v == null || s.size.totalBytes < v.size.totalBytes) v = s;
        }
        return PresetPick(v, audios.isEmpty ? null : audios.last);
      }
    case QualityPreset.audio:
      {
        return PresetPick(null, audios.firstOrNull);
      }
  }
}