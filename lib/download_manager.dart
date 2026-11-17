import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import 'links.dart';
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

/// Tracks a playlist so one summary notification can be shown at the end.
class _Group {
  _Group(this.total);
  final int total;
  int finished = 0;
  int ok = 0;
  int failed = 0;
  bool rateLimited = false;
  bool notified = false;
}

class _Meter {
  DateTime tick = DateTime.now();
  int bytes = 0;
}

class _Cached {
  _Cached(this.info) : at = DateTime.now();
  final VideoInfo info;
  final DateTime at;
}

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
  final YoutubeHttpClient _dl = YoutubeHttpClient(); // for resumable ranges
  final Expando<_Group> _groupOf = Expando<_Group>();
  final math.Random _rng = math.Random();
  int _orderCounter = 0;

  /// Set by the UI: asks whether a big download may use mobile data.
  /// Must return 'now', 'wait' or 'cancel'.
  Future<String> Function(int bytes)? mobileDataPrompt;
  DateTime? _mobileApprovedUntil;
  Future<String>? _promptFuture;

  // ---------- rate limiting ----------

  /// Non-null while new YouTube lookups are paused after a confirmed block.
  final ValueNotifier<DateTime?> rateLimitUntil =
      ValueNotifier<DateTime?>(null);
  Timer? _rateTimer;
  final Map<String, _Cached> _cache = {};
  final Map<String, List<ClosedCaptionTrackInfo>> _capCache = {};
  DateTime _lastApi = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _apiChain = Future.value();

  Duration? _blockedFor() {
    final u = rateLimitUntil.value;
    if (u == null) return null;
    final left = u.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  void _noteRateLimit() {
    rateLimitUntil.value = DateTime.now().add(const Duration(minutes: 10));
    _rateTimer?.cancel();
    _rateTimer =
        Timer(const Duration(minutes: 10), () => rateLimitUntil.value = null);
  }

  /// "Try now": lift the pause and allow lookups again.
  void clearRateLimit() {
    _rateTimer?.cancel();
    rateLimitUntil.value = null;
  }

  /// Runs a YouTube request with a minimum gap between requests, and retries
  /// a rate-limit answer twice (after ~4 s and ~10 s) before giving up.
  Future<T> _api<T>(Future<T> Function() call) {
    final c = Completer<T>();
    _apiChain = _apiChain.then((_) async {
      final gap = const Duration(milliseconds: 1400) -
          DateTime.now().difference(_lastApi);
      if (gap > Duration.zero) {
        await Future<void>.delayed(
            gap + Duration(milliseconds: _rng.nextInt(500)));
      }
      _lastApi = DateTime.now();
      try {
        c.complete(await _withRetry(call));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<T> _withRetry<T>(Future<T> Function() call) async {
    var attempt = 0;
    while (true) {
      try {
        return await call();
      } on RequestLimitExceededException {
        if (attempt >= 2) {
          _noteRateLimit();
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: attempt == 0 ? 4 : 10));
        attempt++;
      }
    }
  }

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

  // ---------- queue, pause, cancel ----------

  /// Downloads waiting for a free slot, in the order they will start.
  List<DownloadTask> get queuedTasks => tasks
      .where((t) => !t.started && t.state == TaskState.queued)
      .toList()
    ..sort((a, b) => a.order.compareTo(b.order));

  int queuePosition(DownloadTask t) => queuedTasks.indexOf(t) + 1;

  void moveQueued(int from, int to) {
    final q = queuedTasks;
    if (from < 0 || from >= q.length || to < 0 || to >= q.length) return;
    final item = q.removeAt(from);
    q.insert(to, item);
    for (var i = 0; i < q.length; i++) {
      q[i].order = i;
    }
    notifyListeners();
  }

  void setMaxConcurrent(int n) {
    settings.update(() => settings.maxConcurrent = n.clamp(1, 4));
    _pump();
  }

  /// Starts waiting downloads while there are free slots.
  void _pump() {
    final max = settings.maxConcurrent.clamp(1, 4);
    var used = tasks
        .where((t) => t.started && t.active && t.state != TaskState.paused)
        .length;
    var changed = false;
    for (final t in queuedTasks) {
      if (used >= max) break;
      final go = t.starter;
      if (go == null) continue;
      t.started = true;
      used++;
      changed = true;
      unawaited(go());
    }
    if (changed) notifyListeners();
  }

  /// Starts one queued download immediately, ignoring the limit.
  void startNow(DownloadTask t) {
    if (t.started || t.state != TaskState.queued) return;
    final go = t.starter;
    if (go == null) return;
    t.started = true;
    unawaited(go());
    notifyListeners();
  }

  void pause(DownloadTask t) {
    if (t.state != TaskState.downloading) return;
    t.pauseRequested = true;
    t.state = TaskState.paused;
    t.speed = 0;
    t.touch();
    notifyListeners();
    syncNotification(force: true);
    _pump();
  }

  void resume(DownloadTask t) {
    if (t.state != TaskState.paused) return;
    t.pauseRequested = false;
    t.state = TaskState.downloading;
    t.touch();
    notifyListeners();
    syncNotification(force: true);
  }

  void cancel(DownloadTask t) {
    if (!t.started && t.state == TaskState.queued) {
      t.state = TaskState.cancelled;
      t.log('Cancelled');
      _closeGroupSlot(t);
      notifyListeners();
      _pump();
      return;
    }
    t.cancelRequested = true;
    t.touch();
  }

  void remove(DownloadTask t) {
    if (!t.started && t.state == TaskState.queued) {
      t.state = TaskState.cancelled;
      _closeGroupSlot(t);
    } else if (t.active) {
      t.cancelRequested = true;
    }
    tasks.remove(t);
    notifyListeners();
    _saveHistory();
    _pump();
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
    final key = normalizeYoutubeInput(url);

    final hit = _cache[key];
    if (hit != null &&
        DateTime.now().difference(hit.at) < const Duration(minutes: 10)) {
      return hit.info; // no new request to YouTube
    }
    final left = _blockedFor();
    if (left != null) {
      throw FetchError(
          'YouTube is limiting this connection. To avoid making it worse, '
          'new lookups are paused for ${fmtDuration(left)}.\n\n'
          'Tap "Try now" in the banner above to override.');
    }

    try {
      final video0 = await _api(() => _yt.videos.get(url));
      final manifest =
          await _api(() => _yt.videos.streams.getManifest(video0.id));
      final video = await _withChapters(video0);
      final info = VideoInfo(video, manifest);
      if (_cache.length > 40) _cache.clear();
      _cache[key] = _Cached(info);
      _cache[video.id.value] = _Cached(info);
      return info;
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

  /// Adds chapters found on YouTube's page when the description has none.
  Future<Video> _withChapters(Video v) async {
    final d = v.duration;
    if (d == null || d < const Duration(minutes: 5)) return v;
    if (parseChapters(v.description, total: d).isNotEmpty) return v;
    if (_blockedFor() != null) return v;
    try {
      final list = await _api(() => _chaptersFromWatchPage(v.id.value, d));
      if (list.isEmpty) return v;
      return v.copyWith(description: '${chaptersToBlock(list)}${v.description}');
    } catch (_) {
      return v;
    }
  }

  Future<List<Chapter>> _chaptersFromWatchPage(String id, Duration total) async {
    final client = HttpClient();
    try {
      client.userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
      final req = await client.getUrl(Uri.parse(
          'https://www.youtube.com/watch?v=$id&hl=en&bpctr=9999999999&has_verified=1'));
      req.headers.set('Accept-Language', 'en-US,en;q=0.9');
      req.headers.set('Cookie', 'CONSENT=YES+1; SOCS=CAI');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode == 429) {
        _noteRateLimit();
        throw FetchError(_rateLimitMsg);
      }
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return const <Chapter>[];
      }
      final html = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      return chaptersFromWatchHtml(html, total: total);
    } finally {
      client.close(force: true);
    }
  }

  Future<PlaylistInfo> fetchPlaylist(String id) async {
    final left = _blockedFor();
    if (left != null) {
      throw FetchError(
          'YouTube is limiting this connection. New lookups are paused for '
          '${fmtDuration(left)} (tap "Try now" in the banner to override).');
    }
    try {
      final pl = await _api(() => _yt.playlists.get(id));
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
    final cached = _capCache[id.value];
    if (cached != null) return cached;
    try {
      final m = await _api(() => _yt.videos.closedCaptions.getManifest(id));
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
      _capCache[id.value] = list;
      return list;
    } catch (_) {
      return [];
    }
  }

  // ---------- adding downloads ----------

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
    t.order = _orderCounter++;
    t.starter = () => _run(t, r);
    tasks.insert(0, t);
    notifyListeners();
    _pump();
  }

  /// Queues many videos with one quality preset (original-language audio).
  /// Each video's qualities are read right before its download starts.
  void enqueueBatch(List<Video> videos, QualityPreset preset) {
    if (videos.isEmpty) return;
    final group = _Group(videos.length);
    final created = <DownloadTask>[];
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
      t.order = _orderCounter++;
      t.log('Queued (playlist)');
      _groupOf[t] = group;
      t.starter = () => _runBatchItem(t, v, preset);
      created.add(t);
    }
    tasks.insertAll(0, created);
    notifyListeners();
    _pump();
  }

  Future<void> _runBatchItem(
      DownloadTask t, Video v, QualityPreset preset) async {
    final g = _groupOf[t];
    void fail(String msg) {
      t.state = TaskState.failed;
      t.error = msg;
      t.log('ERROR: $msg');
      t.touch();
    }

    try {
      t.started = true;
      if (t.cancelRequested || !tasks.contains(t)) {
        t.state = TaskState.cancelled;
        t.touch();
        return;
      }
      if (g != null && g.rateLimited) {
        fail('Skipped: YouTube is rate-limiting this connection.');
        return;
      }
      if (_blockedFor() != null) {
        g?.rateLimited = true;
        fail('Skipped: YouTube is rate-limiting this connection.');
        return;
      }
      await Bg.start();
      t.log('Reading available qualities…');
      final manifest = await _api(() => _yt.videos.streams.getManifest(v.id));
      final pick =
          pickPreset(preset, sortedVideos(manifest), sortedAudios(manifest));
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
      await _run(t, req, notify: g == null || g.total == 1);
    } on RequestLimitExceededException {
      g?.rateLimited = true;
      fail(_rateLimitMsg);
    } catch (err) {
      fail('$err');
    } finally {
      if (g != null) {
        g.finished++;
        if (t.state == TaskState.done) {
          g.ok++;
        } else if (t.state == TaskState.failed) {
          g.failed++;
        }
        await _maybeNotifyGroup(g);
      }
      notifyListeners();
      _pump();
    }
  }

  /// A playlist item that was cancelled/removed before it ever started.
  void _closeGroupSlot(DownloadTask t) {
    final g = _groupOf[t];
    if (g == null) return;
    g.finished++;
    unawaited(_maybeNotifyGroup(g));
  }

  Future<void> _maybeNotifyGroup(_Group g) async {
    if (g.total <= 1 || g.notified || g.finished < g.total) return;
    g.notified = true;
    await Bg.notify(
      'Playlist finished',
      '${g.ok} of ${g.total} saved${g.failed > 0 ? ', ${g.failed} failed' : ''}',
    );
    if (settings.haptics) HapticFeedback.mediumImpact();
  }

  // ---------- network helpers ----------

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

  /// After a connection problem: wait until there is a usable network again
  /// (and Wi-Fi, if "Wi-Fi only" is on). Returns false if cancelled.
  Future<bool> _waitForNetwork(DownloadTask t) async {
    var shown = false;
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (true) {
      final net = await Native.netType();
      final offline = net == 'none';
      final blockedCell =
          settings.wifiOnly && !t.forceMobile && net == 'cellular';
      if (!offline && !blockedCell) {
        if (shown) {
          t.status = null;
          t.touch();
        }
        return true;
      }
      if (t.cancelRequested || !tasks.contains(t)) return false;
      if (DateTime.now().isAfter(deadline)) return true; // try anyway
      if (!shown) {
        shown = true;
        t.status = offline ? 'No connection - waiting…' : 'Waiting for Wi-Fi…';
        t.log(t.status!);
        t.touch();
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  // ---------- extras: thumbnail, tags, subtitles ----------

  /// Downloads the video's cover image (best available) into [tmp].
  Future<File?> _fetchThumbnail(Video v, Directory tmp, String tag) async {
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
        final f = File('${tmp.path}/$tag-cover.jpg');
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
      final xml = await _api(() => _yt.videos.closedCaptions.getSubTitles(track));
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

  // ---------- downloading one stream (pause / resume / reconnect) ----------

  Future<void> _pauseWait(DownloadTask t) async {
    t.state = TaskState.paused;
    t.speed = 0;
    t.status = null;
    t.log('Paused');
    t.touch();
    notifyListeners();
    syncNotification(force: true);
    _pump(); // a paused download does not hold a slot
    while (t.pauseRequested && !t.cancelRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (t.cancelRequested) throw _Cancelled();
    t.state = TaskState.downloading;
    t.log('Resumed');
    t.touch();
    notifyListeners();
    syncNotification(force: true);
  }

  /// Downloads [s] into [f]. Survives pauses and connection drops by
  /// continuing from the byte where it stopped.
  Future<void> _downloadStream(
      DownloadTask t, StreamInfo s, File f, _Meter m) async {
    final expected = s.size.totalBytes;
    final base = t.received;
    var got = 0;
    var failures = 0;
    var restarted = false;
    m.tick = DateTime.now();
    m.bytes = t.received;
    if (await f.exists()) await f.delete();
    var sink = f.openWrite();
    try {
      while (true) {
        if (got >= expected) {
          await sink.flush();
          await sink.close();
          final len = await f.length();
          if (len == expected) return;
          if (restarted) {
            throw StateError(
                'Downloaded file has the wrong size ($len of $expected bytes)');
          }
          restarted = true;
          t.log('Size mismatch ($len / $expected) - restarting this stream');
          await f.delete();
          got = 0;
          t.received = base;
          sink = f.openWrite();
          continue;
        }
        if (t.cancelRequested) throw _Cancelled();
        if (t.pauseRequested) {
          try {
            await sink.flush();
          } catch (_) {}
          await _pauseWait(t);
          m.tick = DateTime.now();
          m.bytes = t.received;
          continue;
        }

        var progressed = false;
        try {
          final Stream<List<int>> stream = got == 0
              ? _yt.videos.streams.get(s)
              : _dl.getStream(s, streamClient: _yt.videos.streams, start: got);
          await for (final chunk in stream) {
            if (t.cancelRequested) throw _Cancelled();
            if (t.pauseRequested) break;
            sink.add(chunk);
            got += chunk.length;
            t.received += chunk.length;
            progressed = true;
            final now = DateTime.now();
            final ms = now.difference(m.tick).inMilliseconds;
            if (ms >= 500) {
              final inst = (t.received - m.bytes) * 1000 / ms;
              t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
              m.tick = now;
              m.bytes = t.received;
              t.progress = t.total == 0 ? 0 : t.received / t.total;
              t.touch();
              syncNotification();
            }
          }
          if (t.pauseRequested) continue;
          if (got < expected) {
            throw const SocketException('The connection closed early');
          }
        } on _Cancelled {
          rethrow;
        } catch (e) {
          if (t.cancelRequested) throw _Cancelled();
          failures = progressed ? 1 : failures + 1;
          if (failures > 6) rethrow;
          t.log('Connection problem: $e');
          try {
            await sink.flush();
          } catch (_) {}
          t.status = 'Connection problem - retrying…';
          t.touch();
          final secs = const [2, 4, 8, 15, 30, 60][math.min(failures, 6) - 1];
          await Future<void>.delayed(Duration(seconds: secs));
          if (!await _waitForNetwork(t)) throw _Cancelled();
          t.status = null;
          m.tick = DateTime.now();
          m.bytes = t.received;
          t.touch();
        }
      }
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }
  }

  // ---------- the download itself ----------

  Future<void> _run(DownloadTask t, DownloadRequest r,
      {bool notify = true}) async {
    t.started = true;
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
      t.status = null;
      notifyListeners();
      t.log('Total to download: ${fmtBytes(t.total)}');

      final tag = t.id; // unique temp names, so parallel downloads never clash
      final id = r.video.id.value;
      final meter = _Meter();

      for (final s in streams) {
        final kind = s is VideoOnlyStreamInfo ? 'video' : 'audio';
        final f = File('${tmp.path}/$tag-$kind.${s.container.name}');
        temp.add(f);
        t.log('Downloading $kind stream: '
            '${s is VideoOnlyStreamInfo ? describeVideo(s) : describeAudio(s as AudioOnlyStreamInfo)}');
        await _downloadStream(t, s, f, meter);
        t.log('Finished $kind stream');
      }

      t.progress = 1;
      t.speed = 0;
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
        cover = await _fetchThumbnail(r.video, tmp, tag);
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
        final processed = File('${tmp.path}/$tag-out.$ext');
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
      t.status = null;
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
      _pump(); // a slot is free: start the next waiting download
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
      TaskState.paused => 'Paused',
      TaskState.queued => 'Waiting in queue…',
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