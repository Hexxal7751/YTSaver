import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'audio_tracks.dart';
import 'background.dart';
import 'extras.dart';
import 'filenames.dart';
import 'models.dart';
import 'native.dart';
import 'presets.dart';
import 'settings.dart';

class VideoInfo {
  VideoInfo(this.video, this.manifest);
  final Video video;
  final StreamManifest manifest;
}

class PlaylistInfo {
  PlaylistInfo(this.title, this.author, this.videos);
  final String title;
  final String author;
  final List<Video> videos;
}

class DownloadRequest {
  DownloadRequest(
    this.video, {
    this.videoStream,
    this.audioStream,
    this.trim,
    this.thumbnail = false,
    this.tags = false,
    this.subtitle,
    this.chapterTitle,
  });

  final Video video;
  final VideoOnlyStreamInfo? videoStream;
  final AudioOnlyStreamInfo? audioStream;
  final TrimRange? trim;
  final bool thumbnail; // save the cover image next to the file
  final bool tags; // embed title/artist/cover (audio-only downloads)
  final ClosedCaptionTrackInfo? subtitle;
  final String? chapterTitle;

  /// Title used for the task card.
  String get displayTitle => (chapterTitle != null && chapterTitle!.isNotEmpty)
      ? '$chapterTitle — ${video.title}'
      : video.title;

  /// Title used for the {title} part of the file name.
  String get nameTitle {
    final c = chapterTitle;
    if (c != null && c.isNotEmpty) return '${video.title} - $c';
    final t = trim;
    if (t != null) {
      return '${video.title} [${compactTime(t.start)}-${compactTime(t.end)}]';
    }
    return video.title;
  }
}

/// A playlist item waiting for its qualities to be read (used by Retry).
class BatchItem {
  BatchItem(this.video, this.preset);
  final Video video;
  final QualityPreset preset;
}

/// Error with a human-readable message (shown directly in the UI).
class FetchError implements Exception {
  FetchError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

const _rateLimitMsg =
    'YouTube is rate-limiting this connection (too many requests from '
    'this IP address).\n\nWait 30-60 minutes, or switch between Wi-Fi '
    'and mobile data (toggling airplane mode also helps) to get a new '
    'IP, then try again.';

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

String describeAudio(AudioOnlyStreamInfo s) {
  final lang = s.audioTrack?.displayName ?? '';
  return '${lang.isEmpty ? '' : '$lang · '}${acodecName(s.audioCodec)} · '
      '${s.bitrate.kiloBitsPerSecond.round()} kbps · '
      '${s.container.name} · ${fmtBytes(s.size.totalBytes)}';
}

String _addNote(String? old, String add) => old == null ? add : '$old $add';

/// Text safe to put inside a quoted ffmpeg argument.
String _q(String s) => s
    .replaceAll('"', "'")
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    .trim();

String _secs(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(3);

class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> tasks = [];
  final YoutubeExplode _yt = YoutubeExplode();

  /// Set by the UI: asks whether a big download may use mobile data.
  /// Must return 'now', 'wait' or 'cancel'.
  Future<String> Function(int bytes)? mobileDataPrompt;
  DateTime? _mobileApprovedUntil;
  Future<String>? _promptFuture;

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

  /// Removes finished entries whose file no longer exists.
  Future<void> pruneMissing() async {
    final gone = <DownloadTask>[];
    for (final t in tasks) {
      if (t.state == TaskState.done) {
        final p = t.outputPath;
        if (p == null || !await File(p).exists()) gone.add(t);
      }
    }
    if (gone.isNotEmpty) {
      tasks.removeWhere(gone.contains);
      notifyListeners();
      _saveHistory();
    }
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
    } else if (r is BatchItem) {
      tasks.remove(t);
      enqueueBatch([r.video], r.preset);
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
      throw FetchError(_rateLimitMsg);
    } on ArgumentError {
      throw FetchError('That does not look like a valid YouTube link.');
    } on YoutubeExplodeException catch (e) {
      final msg = '$e';
      throw FetchError(
          'YouTube error: ${msg.length > 300 ? msg.substring(0, 300) : msg}');
    }
  }

  Future<PlaylistInfo> fetchPlaylist(String id) async {
    try {
      final pl = await _yt.playlists.get(id);
      final vids = <Video>[];
      await for (final v in _yt.playlists.getVideos(id)) {
        vids.add(v);
        if (vids.length >= 300) break;
      }
      if (vids.isEmpty) {
        throw FetchError('This playlist is empty or private.');
      }
      return PlaylistInfo(pl.title, pl.author, vids);
    } on RequestLimitExceededException {
      throw FetchError(_rateLimitMsg);
    } on ArgumentError {
      throw FetchError('That does not look like a valid playlist link.');
    } on YoutubeExplodeException catch (e) {
      final msg = '$e';
      throw FetchError(
          'Could not load the playlist: ${msg.length > 300 ? msg.substring(0, 300) : msg}');
    }
  }

  /// Subtitle languages offered for a video (manual ones first).
  Future<List<ClosedCaptionTrackInfo>> fetchCaptionTracks(VideoId id) async {
    try {
      final m = await _yt.videos.closedCaptions.getManifest(id);
      final byLang = <String, ClosedCaptionTrackInfo>{};
      for (final t in m.tracks) {
        if (t.format != ClosedCaptionFormat.srv1) continue;
        byLang['${t.language.code}|${t.isAutoGenerated}'] = t;
      }
      final list = byLang.values.toList()
        ..sort((a, b) {
          if (a.isAutoGenerated != b.isAutoGenerated) {
            return a.isAutoGenerated ? 1 : -1;
          }
          return a.language.name.compareTo(b.language.name);
        });
      return list;
    } catch (_) {
      return [];
    }
  }

  // ---------- downloading ----------

  void enqueue(DownloadRequest r) {
    final a = r.audioStream;
    final base = [
      if (r.videoStream != null) r.videoStream!.qualityLabel,
      if (a != null) '${a.bitrate.kiloBitsPerSecond.round()}kbps',
    ].join(' + ');
    // Mention the language in the name when it is not the original track.
    final lang = (a != null && a.audioTrack != null && !isOriginalTrack(a))
        ? a.audioTrack!.displayName
        : '';
    final label = lang.isEmpty ? base : '$base · $lang';
    final t = DownloadTask(
      title: r.displayTitle,
      label: label,
      videoId: r.video.id.value,
      thumbnailUrl: r.video.thumbnails.mediumResUrl,
      channel: r.video.author,
      videoDuration: r.trim?.length ?? r.video.duration,
      audioOnly: r.videoStream == null,
    );
    t.retryPayload = r;
    tasks.insert(0, t);
    notifyListeners();
    _run(t, r);
  }

  // ---------- playlist / batch ----------

  Future<void> _batchChain = Future.value();

  /// Queues many videos with one quality preset (original-language audio).
  /// They are processed one at a time (qualities are read right before each
  /// download) to stay under YouTube's rate limits.
  void enqueueBatch(List<Video> videos, QualityPreset preset) {
    if (videos.isEmpty) return;
    final items = <MapEntry<DownloadTask, Video>>[];
    for (final v in videos) {
      final t = DownloadTask(
        title: v.title,
        label: preset.title,
        videoId: v.id.value,
        thumbnailUrl: v.thumbnails.mediumResUrl,
        channel: v.author,
        videoDuration: v.duration,
        audioOnly: preset == QualityPreset.audio,
      );
      t.retryPayload = BatchItem(v, preset);
      t.log('Queued (playlist)');
      items.add(MapEntry(t, v));
    }
    tasks.insertAll(0, items.map((e) => e.key));
    notifyListeners();
    _batchChain = _batchChain.then((_) => _processBatch(items, preset));
  }

  Future<void> _processBatch(
    List<MapEntry<DownloadTask, Video>> items,
    QualityPreset preset,
  ) async {
    var ok = 0;
    var failed = 0;
    var rateLimited = false;
    try {
      await Bg.start();
      for (final e in items) {
        final t = e.key;
        final v = e.value;
        if (!tasks.contains(t)) continue; // removed by the user
        if (t.cancelRequested) {
          t.state = TaskState.cancelled;
          t.touch();
          continue;
        }
        if (rateLimited) {
          t.state = TaskState.failed;
          t.error = 'Skipped: YouTube is rate-limiting this connection.';
          t.touch();
          failed++;
          continue;
        }
        try {
          t.log('Reading available qualities…');
          final manifest = await _yt.videos.streams.getManifest(v.id);
          final pick = pickPreset(
              preset, sortedVideos(manifest), sortedAudios(manifest));
          if (!pick.valid) throw FetchError('No suitable streams found.');
          t.label = [
            if (pick.video != null) pick.video!.qualityLabel,
            if (pick.audio != null)
              '${pick.audio!.bitrate.kiloBitsPerSecond.round()}kbps',
          ].join(' + ');
          final req = DownloadRequest(v,
              videoStream: pick.video,
              audioStream: pick.audio,
              tags: pick.video == null);
          await _run(t, req, notify: false);
        } on RequestLimitExceededException {
          rateLimited = true;
          t.state = TaskState.failed;
          t.error = _rateLimitMsg;
          t.log('ERROR: rate limited');
          t.touch();
        } catch (err) {
          t.state = TaskState.failed;
          t.error = '$err';
          t.log('ERROR: $err');
          t.touch();
        }
        if (t.state == TaskState.done) {
          ok++;
        } else if (t.state == TaskState.failed) {
          failed++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } finally {
      final total = items.length;
      await Bg.notify(
        'Playlist finished',
        '$ok of $total saved${failed > 0 ? ', $failed failed' : ''}',
      );
      if (settings.haptics) HapticFeedback.mediumImpact();
      notifyListeners();
      syncNotification(force: true);
    }
  }

  Future<Directory> _outDir(bool audioOnly) async {
    final base = audioOnly ? settings.audioPath : settings.videoPath;
    try {
      final d = Directory(base);
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
  }

  /// Handles "Wi-Fi only" and the big-download warning on mobile data.
  /// Returns false if the user cancelled (or the task was removed).
  Future<bool> _networkGate(DownloadTask t, int bytes) async {
    var net = await Native.netType();
    if (net != 'cellular') return true;

    var waitForWifi = settings.wifiOnly;
    if (!waitForWifi) {
      final limit = settings.warnMobileMb * 1024 * 1024;
      final until = _mobileApprovedUntil;
      final approved = until != null && DateTime.now().isBefore(until);
      if (settings.warnMobileMb <= 0 || bytes <= limit || approved) {
        return true;
      }
      final prompt = mobileDataPrompt;
      var choice = 'now';
      if (prompt != null) {
        final future = _promptFuture ??=
            prompt(bytes).whenComplete(() => _promptFuture = null);
        choice = await future;
      }
      if (choice == 'cancel') return false;
      if (choice == 'now') {
        _mobileApprovedUntil = DateTime.now().add(const Duration(minutes: 15));
        return true;
      }
      waitForWifi = true;
    }

    if (waitForWifi) {
      t.state = TaskState.waitingWifi;
      t.log('Waiting for Wi-Fi…');
      t.touch();
      notifyListeners();
      syncNotification(force: true);
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (t.cancelRequested || !tasks.contains(t)) return false;
        if (t.forceMobile) {
          t.log('Using mobile data (your choice)');
          return true;
        }
        net = await Native.netType();
        if (net != 'cellular') break;
      }
      t.log('Wi-Fi connected');
    }
    return true;
  }

  // ---------- extras: thumbnail, tags, subtitles ----------

  /// Downloads the video's cover image (best available) into [tmp].
  Future<File?> _fetchThumbnail(Video v, Directory tmp) async {
    final urls = <String>[v.thumbnails.maxResUrl, v.thumbnails.highResUrl];
    for (final u in urls) {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(u));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          continue;
        }
        final f = File('${tmp.path}/${v.id.value}-cover.jpg');
        await resp.pipe(f.openWrite());
        if (await f.length() > 2000) return f;
      } catch (_) {
        // try the next size
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Map<String, String> _tagMeta(DownloadRequest r) {
    final v = r.video;
    final artist = v.author.replaceAll(RegExp(r'\s*-\s*Topic$'), '');
    final map = <String, String>{
      'title': (r.chapterTitle != null && r.chapterTitle!.isNotEmpty)
          ? r.chapterTitle!
          : v.title,
      'artist': artist,
      'album': v.title,
      'date': v.uploadDate == null ? '' : '${v.uploadDate!.year}',
      'comment': 'https://youtu.be/${v.id.value}',
    };
    map.removeWhere((k, val) => val.trim().isEmpty);
    return map;
  }

  Future<void> _saveSubtitles(
      DownloadTask t, DownloadRequest r, String stem) async {
    final track = r.subtitle!;
    try {
      t.log('Fetching subtitles (${track.language.code})…');
      final xml = await _yt.videos.closedCaptions.getSubTitles(track);
      final cues = parseCaptions(xml);
      if (cues.isEmpty) {
        t.log('YouTube returned no subtitle text');
        t.note = _addNote(t.note, 'Saved, but the subtitles were unavailable.');
        return;
      }
      final srt = buildSrt(cues, from: r.trim?.start, to: r.trim?.end);
      final path = '$stem.${track.language.code}.srt';
      await File(path).writeAsString(srt);
      t.log('Saved subtitles: $path');
    } catch (e) {
      t.log('Subtitles failed: $e');
      t.note = _addNote(t.note, 'Saved, but the subtitles could not be downloaded.');
    }
  }

  // ---------- the download itself ----------

  Future<void> _run(DownloadTask t, DownloadRequest r,
      {bool notify = true}) async {
    final temp = <File>[]; // downloaded streams
    final extra = <File>[]; // cover + processed output
    try {
      await Bg.start();
      final tmp = await getTemporaryDirectory();
      final streams = <StreamInfo>[
        if (r.videoStream != null) r.videoStream!,
        if (r.audioStream != null) r.audioStream!,
      ];
      t.total = streams.fold(0, (s, e) => s + e.size.totalBytes);

      if (!await _networkGate(t, t.total)) throw _Cancelled();

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
      final base = renderName(
        settings.filenameTemplate,
        title: r.nameTitle,
        quality: t.label,
        channel: r.video.author,
        id: id,
      );
      final out = uniquePath(dir.path, base, ext);
      final stem = out.substring(0, out.length - ext.length - 1);

      final trim = r.trim;
      final needTags = r.tags && audioOnly;
      final embedCover = needTags && ext == 'm4a';

      File? cover;
      if (r.thumbnail || embedCover) {
        cover = await _fetchThumbnail(r.video, tmp);
        if (cover == null) {
          t.log('Thumbnail unavailable');
        } else {
          extra.add(cover);
        }
      }

      final needFfmpeg = temp.length == 2 || trim != null || needTags;
      if (needFfmpeg) {
        t.state = TaskState.merging;
        t.log(temp.length == 2
            ? 'Merging with ffmpeg -> $ext'
            : 'Processing with ffmpeg -> $ext');
        notifyListeners();
        syncNotification(force: true);

        // Work inside the app's private cache, then copy to public storage.
        final processed = File('${tmp.path}/$id-out.$ext');
        extra.add(processed);
        try {
          final cmd = _buildCommand(
            inputs: temp,
            outPath: processed.path,
            hasVideo: !audioOnly,
            trim: trim,
            cover: embedCover ? cover : null,
            meta: needTags ? _tagMeta(r) : const <String, String>{},
          );
          await _ffmpeg(t, cmd, processed.path);
          t.log('Copying result to $out');
          await processed.copy(out);
          t.outputPath = out;
        } on _Cancelled {
          rethrow;
        } catch (e) {
          t.log('Processing failed: $e');
          if (temp.length == 2) {
            t.log('Saving video and audio as separate files instead…');
            final vExt = r.videoStream!.container.name;
            final aExt = r.audioStream!.container.name == 'mp4' ? 'm4a' : 'webm';
            final vOut = uniquePath(dir.path, '$base video', vExt);
            final aOut = uniquePath(dir.path, '$base audio', aExt);
            await temp[0].copy(vOut);
            await temp[1].copy(aOut);
            t.outputPath = vOut;
            t.note = _addNote(
                t.note,
                'Merge failed, so video and audio were saved separately '
                'in ${dir.path}');
          } else {
            t.log('Saving the original file instead…');
            await temp.first.copy(out);
            t.outputPath = out;
            t.note = _addNote(t.note,
                'Saved, but trimming/tagging failed, so the original file was kept.');
          }
        }
      } else {
        await temp.first.copy(out);
        t.outputPath = out;
      }

      if (r.thumbnail && cover != null) {
        try {
          await cover.copy('$stem.jpg');
          t.log('Saved thumbnail: $stem.jpg');
        } catch (e) {
          t.log('Thumbnail not saved: $e');
        }
      }
      if (r.subtitle != null) await _saveSubtitles(t, r, stem);

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
        if (notify) {
          if (settings.haptics) HapticFeedback.mediumImpact();
          await Bg.notify('Download complete', t.title);
        }
      } else if (t.state == TaskState.failed && notify) {
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
    final working = active
        .where((x) =>
            x.state == TaskState.downloading || x.state == TaskState.merging)
        .toList();
    final first = working.isNotEmpty ? working.first : active.first;
    final pct = (first.progress * 100).round();
    final text = switch (first.state) {
      TaskState.merging => 'Processing…',
      TaskState.waitingWifi => 'Waiting for Wi-Fi…',
      _ => '$pct% · ${fmtBytes(first.speed)}/s',
    };
    Bg.update(
      active.length > 1
          ? '${active.length} downloads · ${first.title}'
          : first.title,
      text,
    );
  }

  // ---------- ffmpeg ----------

  /// Builds the ffmpeg command: merges, trims and/or tags without re-encoding.
  String _buildCommand({
    required List<File> inputs,
    required String outPath,
    required bool hasVideo,
    TrimRange? trim,
    File? cover,
    Map<String, String> meta = const <String, String>{},
  }) {
    final a = <String>['-y', '-nostdin'];
    for (final f in inputs) {
      if (trim != null) a.addAll(['-ss', _secs(trim.start)]);
      a.addAll(['-i', '"${f.path}"']);
    }
    if (cover != null) a.addAll(['-i', '"${cover.path}"']);

    if (inputs.length == 2) {
      a.addAll(['-map', '0:v:0', '-map', '1:a:0']);
    } else if (hasVideo) {
      a.addAll(['-map', '0:v:0']);
    } else {
      a.addAll(['-map', '0:a:0']);
    }
    if (cover != null) a.addAll(['-map', '${inputs.length}:v:0']);

    if (trim != null) a.addAll(['-t', _secs(trim.length)]);
    a.addAll(['-c', 'copy']);
    if (cover != null) a.addAll(['-disposition:v:0', 'attached_pic']);
    meta.forEach((k, v) => a.addAll(['-metadata', '"$k=${_q(v)}"']));
    a.add('"$outPath"');
    return a.join(' ');
  }

  /// Runs ffmpeg with a watchdog: aborts if there is no log/stat output and
  /// the output file stops growing for 90 seconds, or if the user cancels.
  Future<void> _ffmpeg(DownloadTask t, String cmd, String outPath) async {
    final c = Completer<void>();
    var lastActivity = DateTime.now();
    var lastLen = -1;
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