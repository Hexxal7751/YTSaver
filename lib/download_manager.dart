import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'background.dart';
import 'models.dart';
import 'settings.dart';

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

/// Error with a human-readable message (shown directly in the UI).
class FetchError implements Exception {
  FetchError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

String vcodecName(String c) {
  if (c.startsWith('avc')) return 'H.264';
  if (c.startsWith('vp09') || c.startsWith('vp9')) return 'VP9';
  if (c.startsWith('av01')) return 'AV1';
  return c;
}

String acodecName(String c) {
  if (c.startsWith('mp4a')) return 'AAC';
  if (c.contains('opus')) return 'Opus';
  return c;
}

String describeVideo(VideoOnlyStreamInfo s) =>
    '${s.qualityLabel} · ${vcodecName(s.videoCodec)} · ${s.container.name} · '
    '${fmtBytes(s.size.totalBytes)}';

String describeAudio(AudioOnlyStreamInfo s) =>
    '${acodecName(s.audioCodec)} · ${s.bitrate.kiloBitsPerSecond.round()} kbps · '
    '${s.container.name} · ${fmtBytes(s.size.totalBytes)}';

class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> tasks = [];
  final YoutubeExplode _yt = YoutubeExplode();

  // ---------- history (saved on disk) ----------

  Future<void>? _histLoad;
  Future<void> loadHistory() => _histLoad ??= _loadHistory();

  Future<File> _historyFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/history.json');

  Future<void> _loadHistory() async {
    try {
      final f = await _historyFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      for (final e in list) {
        final t = DownloadTask.fromJson(e as Map<String, dynamic>);
        final p = t.outputPath;
        if (p != null && await File(p).exists()) tasks.add(t);
      }
      tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      await loadHistory();
      final done = tasks
          .where((t) => t.state == TaskState.done)
          .take(200)
          .map((t) => t.toJson())
          .toList();
      await (await _historyFile()).writeAsString(jsonEncode(done));
    } catch (_) {}
  }

  // ---------- list management ----------

  void remove(DownloadTask t) {
    if (t.active) t.cancelRequested = true;
    tasks.remove(t);
    notifyListeners();
    _saveHistory();
  }

  void clearFinished() {
    tasks.removeWhere((t) => !t.active);
    notifyListeners();
    _saveHistory();
  }

  Future<void> deleteWithFile(DownloadTask t) async {
    try {
      final p = t.outputPath;
      if (p != null) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    remove(t);
  }

  void retry(DownloadTask t) {
    final r = t.retryPayload;
    if (r is DownloadRequest) {
      tasks.remove(t);
      enqueue(r);
    }
  }

  // ---------- fetching ----------

  Future<VideoInfo> fetch(String input) async {
    // Links never contain whitespace; pasted text sometimes does.
    final url = input.replaceAll(RegExp(r'\s'), '');
    try {
      final video = await _yt.videos.get(url);
      final manifest = await _yt.videos.streams.getManifest(video.id);
      return VideoInfo(video, manifest);
    } on RequestLimitExceededException {
      throw FetchError(
          'YouTube is rate-limiting this connection (too many requests from '
          'this IP address).\n\nWait 30-60 minutes, or switch between Wi-Fi '
          'and mobile data (toggling airplane mode also helps) to get a new '
          'IP, then try again.');
    } on ArgumentError {
      throw FetchError('That does not look like a valid YouTube link.');
    } on YoutubeExplodeException catch (e) {
      final msg = '$e';
      throw FetchError(
          'YouTube error: ${msg.length > 300 ? msg.substring(0, 300) : msg}');
    }
  }

  // ---------- downloading ----------

  void enqueue(DownloadRequest r) {
    final label = [
      if (r.videoStream != null) r.videoStream!.qualityLabel,
      if (r.audioStream != null)
        '${r.audioStream!.bitrate.kiloBitsPerSecond.round()}kbps',
    ].join(' + ');
    final t = DownloadTask(
      title: r.video.title,
      label: label,
      videoId: r.video.id.value,
      thumbnailUrl: r.video.thumbnails.mediumResUrl,
      channel: r.video.author,
      videoDuration: r.video.duration,
      audioOnly: r.videoStream == null,
    );
    t.retryPayload = r;
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
    final temp = <File>[]; // downloaded streams
    final extra = <File>[]; // merged temp output
    try {
      await Bg.start();
      final tmp = await getTemporaryDirectory();
      final streams = <StreamInfo>[
        if (r.videoStream != null) r.videoStream!,
        if (r.audioStream != null) r.audioStream!,
      ];
      t.total = streams.fold(0, (s, e) => s + e.size.totalBytes);
      t.state = TaskState.downloading;
      notifyListeners();
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
              syncNotification();
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
        notifyListeners();
        syncNotification(force: true);

        // Merge inside the app's private cache, then copy to public storage.
        final merged = File('${tmp.path}/$id-merged.$ext');
        extra.add(merged);
        try {
          await _merge(t, temp[0], temp[1], merged.path);
          t.log('Copying merged file to $out');
          await merged.copy(out);
          t.outputPath = out;
        } on _Cancelled {
          rethrow;
        } catch (e) {
          t.log('Merge failed: $e');
          t.log('Saving video and audio as separate files instead…');
          final vExt = r.videoStream!.container.name;
          final aExt = r.audioStream!.container.name == 'mp4' ? 'm4a' : 'webm';
          final vOut = '${dir.path}/$name [${t.label}] video.$vExt';
          final aOut = '${dir.path}/$name [${t.label}] audio.$aExt';
          await temp[0].copy(vOut);
          await temp[1].copy(aOut);
          t.outputPath = vOut;
          t.note = 'Merge failed, so video and audio were saved separately '
              'in ${dir.path}';
        }
      } else {
        await temp.first.copy(out);
        t.outputPath = out;
      }
      try {
        t.fileBytes = await File(t.outputPath!).length();
      } catch (_) {}
      t.state = TaskState.done;
      t.log('Saved: ${t.outputPath}');
    } on _Cancelled {
      t.state = TaskState.cancelled;
      t.log('Cancelled');
    } catch (e) {
      t.state = TaskState.failed;
      t.error = '$e';
      t.log('ERROR: $e');
    } finally {
      for (final f in [...temp, ...extra]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      t.touch();
      notifyListeners();
      if (t.state == TaskState.done) {
        _saveHistory();
        if (settings.haptics) HapticFeedback.mediumImpact();
        await Bg.notify('Download complete', t.title);
      } else if (t.state == TaskState.failed) {
        if (settings.haptics) HapticFeedback.heavyImpact();
        await Bg.notify('Download failed', t.title);
      }
      syncNotification(force: true);
    }
  }

  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// Updates the ongoing notification, or stops the service when idle.
  void syncNotification({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSync).inMilliseconds < 1000) return;
    _lastSync = now;
    final active = tasks.where((x) => x.active).toList();
    if (active.isEmpty) {
      Bg.stop();
      return;
    }
    final first = active.first;
    final pct = (first.progress * 100).round();
    final text = first.state == TaskState.merging
        ? 'Merging video + audio…'
        : '$pct% · ${fmtBytes(first.speed)}/s';
    Bg.update(
      active.length > 1 ? '${active.length} downloads' : first.title,
      active.length > 1 ? 'Working in the background…' : text,
    );
  }

  /// Runs ffmpeg with a watchdog: aborts if there is no log/stat output and
  /// the output file stops growing for 90 seconds, or if the user cancels.
  Future<void> _merge(DownloadTask t, File v, File a, String outPath) async {
    final c = Completer<void>();
    var lastActivity = DateTime.now();
    var lastLen = -1;
    final cmd = '-y -nostdin -i "${v.path}" -i "${a.path}" '
        '-map 0:v:0 -map 1:a:0 -c copy "$outPath"';
    t.log('ffmpeg $cmd');

    final watchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (c.isCompleted) return;
      if (t.cancelRequested) {
        FFmpegKit.cancel();
        if (!c.isCompleted) c.completeError(_Cancelled());
        return;
      }
      try {
        final f = File(outPath);
        if (await f.exists()) {
          final len = await f.length();
          if (len != lastLen) {
            lastLen = len;
            lastActivity = DateTime.now();
          }
        }
      } catch (_) {}
      if (DateTime.now().difference(lastActivity).inSeconds > 90) {
        t.log('ffmpeg showed no activity for 90s - aborting');
        FFmpegKit.cancel();
        if (!c.isCompleted) {
          c.completeError('ffmpeg stalled (no activity for 90s)');
        }
      }
    });

    try {
      await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          if (c.isCompleted) return;
          if (ReturnCode.isSuccess(rc)) {
            c.complete();
          } else {
            c.completeError('ffmpeg failed (code ${rc?.getValue()})');
          }
        },
        (log) {
          lastActivity = DateTime.now();
          final m = log.getMessage().trim();
          if (m.isNotEmpty) t.log(m);
        },
        (stats) {
          lastActivity = DateTime.now();
        },
      );
      await c.future;
    } finally {
      watchdog.cancel();
    }
  }
}

final manager = DownloadManager();