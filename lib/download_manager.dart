import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_minimal/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_minimal/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';

class VideoInfo {
  VideoInfo(this.video, this.manifest);
  final Video video;
  final StreamManifest manifest;
}

class DownloadRequest {
  DownloadRequest(this.video, {this.videoStream, this.audioStream});
  final Video video;
  final VideoOnlyStreamInfo? videoStream;
  final AudioOnlyStreamInfo? audioStream;
}

class _Cancelled implements Exception {}

String describeVideo(VideoOnlyStreamInfo s) =>
    '${s.qualityLabel} · ${_vcodec(s.videoCodec)} · ${s.container.name} · '
    '${fmtBytes(s.size.totalBytes)}';

String describeAudio(AudioOnlyStreamInfo s) =>
    '${_acodec(s.audioCodec)} · ${s.bitrate.kiloBitsPerSecond.round()} kbps · '
    '${s.container.name} · ${fmtBytes(s.size.totalBytes)}';

String _vcodec(String c) {
  if (c.startsWith('avc')) return 'H.264';
  if (c.startsWith('vp09') || c.startsWith('vp9')) return 'VP9';
  if (c.startsWith('av01')) return 'AV1';
  return c;
}

String _acodec(String c) {
  if (c.startsWith('mp4a')) return 'AAC';
  if (c.contains('opus')) return 'Opus';
  return c;
}

class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> tasks = [];
  final YoutubeExplode _yt = YoutubeExplode();

  Future<VideoInfo> fetch(String url) async {
    final video = await _yt.videos.get(url);
    final manifest = await _yt.videos.streams.getManifest(video.id);
    return VideoInfo(video, manifest);
  }

  void enqueue(DownloadRequest r) {
    final label = [
      if (r.videoStream != null) r.videoStream!.qualityLabel,
      if (r.audioStream != null)
        '${r.audioStream!.bitrate.kiloBitsPerSecond.round()}kbps',
    ].join(' + ');
    final t = DownloadTask(title: r.video.title, label: label);
    tasks.insert(0, t);
    notifyListeners();
    _run(t, r);
  }

  Future<Directory> _outDir(bool audioOnly) async {
    final base = audioOnly
        ? '/storage/emulated/0/Music/YTSaver'
        : '/storage/emulated/0/Movies/YTSaver';
    try {
      final d = Directory(base);
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
  }

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), '_').trim();

  Future<void> _run(DownloadTask t, DownloadRequest r) async {
    final temp = <File>[];
    try {
      final tmp = await getTemporaryDirectory();
      final streams = <StreamInfo>[
        if (r.videoStream != null) r.videoStream!,
        if (r.audioStream != null) r.audioStream!,
      ];
      t.total = streams.fold(0, (s, e) => s + e.size.totalBytes);
      t.state = TaskState.downloading;
      t.log('Total to download: ${fmtBytes(t.total)}');

      var lastTick = DateTime.now();
      var lastBytes = 0;
      final id = r.video.id.value;

      for (final s in streams) {
        final kind = s is VideoOnlyStreamInfo ? 'video' : 'audio';
        final f = File('${tmp.path}/$id-$kind.${s.container.name}');
        temp.add(f);
        t.log('Downloading $kind stream: '
            '${s is VideoOnlyStreamInfo ? describeVideo(s) : describeAudio(s as AudioOnlyStreamInfo)}');
        final sink = f.openWrite();
        try {
          await for (final chunk in _yt.videos.streams.get(s)) {
            if (t.cancelRequested) throw _Cancelled();
            sink.add(chunk);
            t.received += chunk.length;
            final now = DateTime.now();
            final ms = now.difference(lastTick).inMilliseconds;
            if (ms >= 500) {
              final inst = (t.received - lastBytes) * 1000 / ms;
              t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
              lastTick = now;
              lastBytes = t.received;
              t.progress = t.total == 0 ? 0 : t.received / t.total;
              t.touch();
            }
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        t.log('Finished $kind stream');
      }

      t.progress = 1;
      final audioOnly = r.videoStream == null;
      final dir = await _outDir(audioOnly);
      final name = _safe(r.video.title);
      String ext;
      if (r.videoStream != null && r.audioStream != null) {
        ext = (r.videoStream!.container.name == 'mp4' &&
                r.audioStream!.container.name == 'mp4')
            ? 'mp4'
            : 'mkv';
      } else if (r.videoStream != null) {
        ext = r.videoStream!.container.name;
      } else {
        ext = r.audioStream!.container.name == 'mp4' ? 'm4a' : 'webm';
      }
      final out = '${dir.path}/$name [${t.label}].$ext';

      if (temp.length == 2) {
        t.state = TaskState.merging;
        t.log('Merging with ffmpeg -> $ext');
        t.touch();
        await _merge(t, temp[0], temp[1], out, r.video.duration);
      } else {
        await temp.first.copy(out);
      }
      t.outputPath = out;
      t.state = TaskState.done;
      t.log('Saved: $out');
    } on _Cancelled {
      t.state = TaskState.cancelled;
      t.log('Cancelled');
    } catch (e) {
      t.state = TaskState.failed;
      t.error = '$e';
      t.log('ERROR: $e');
    } finally {
      for (final f in temp) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      t.touch();
    }
  }

  Future<void> _merge(
      DownloadTask t, File v, File a, String out, Duration? dur) {
    final c = Completer<void>();
    final cmd =
        '-y -i "${v.path}" -i "${a.path}" -map 0:v:0 -map 1:a:0 -c copy "$out"';
    FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          c.complete();
        } else {
          c.completeError('ffmpeg failed (code ${rc?.getValue()})');
        }
      },
      (log) {
        final m = log.getMessage().trim();
        if (m.isNotEmpty) t.log(m);
      },
      (stats) {
        if (dur != null && dur.inMilliseconds > 0) {
          t.progress = (stats.getTime() / dur.inMilliseconds).clamp(0.0, 1.0);
          t.touch();
        }
      },
    );
    return c.future;
  }
}

final manager = DownloadManager();
