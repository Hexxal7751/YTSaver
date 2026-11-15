import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../audio_tracks.dart';
import '../download_manager.dart';
import '../links.dart';
import '../models.dart';
import '../presets.dart';
import '../settings.dart';
import '../share_intake.dart';
import '../theme.dart';
import 'widgets.dart';

enum Mode { both, videoOnly, audioOnly }

class GetTab extends StatefulWidget {
  const GetTab({super.key, required this.onQueued});
  final VoidCallback onQueued;
  @override
  State<GetTab> createState() => _GetTabState();
}

class _GetTabState extends State<GetTab> with WidgetsBindingObserver {
  final _ctrl = TextEditingController();

  // single video
  VideoInfo? _info;
  List<VideoOnlyStreamInfo> _videos = [];
  List<AudioTrackGroup> _tracks = [];
  AudioTrackGroup? _track; // currently selected audio language
  VideoOnlyStreamInfo? _v;
  AudioOnlyStreamInfo? _a;
  Mode _mode = Mode.both;
  bool _isShort = false;
  bool _custom = false;
  String? _linkedPlaylistId;

  // playlist
  PlaylistInfo? _playlist;
  final Set<String> _sel = {};
  QualityPreset _batchPreset = QualityPreset.best;

  bool _loading = false;
  String? _error;
  String? _clipLink;

  /// Audio streams of the selected language, best first.
  List<AudioOnlyStreamInfo> get _audios =>
      _track?.streams ?? <AudioOnlyStreamInfo>[];

  AudioTrackGroup? get _defaultTrack => defaultTrack(_tracks);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sharedLink.addListener(_onShared);
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboard();
      _onShared();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sharedLink.removeListener(_onShared);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  // A link was shared from another app (Share -> YTSaver).
  void _onShared() {
    final e = sharedLink.value;
    if (e == null || e.handled || !mounted) return;
    e.handled = true;
    final link = extractYoutubeLink(e.text) ?? e.text.trim();
    if (link.isNotEmpty) _fetch(link);
  }

  Future<void> _checkClipboard() async {
    if (!settings.watchClipboard) {
      if (_clipLink != null && mounted) setState(() => _clipLink = null);
      return;
    }
    try {
      final d = await Clipboard.getData('text/plain');
      final t = d?.text?.trim();
      final link = (t != null && looksLikeYoutube(t) && t != _ctrl.text.trim())
          ? t
          : null;
      if (mounted && link != _clipLink) setState(() => _clipLink = link);
    } catch (_) {}
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text?.trim();
    if (t != null && t.isNotEmpty) _fetch(t);
  }

  Future<void> _fetch([String? link]) async {
    if (link != null) _ctrl.text = link;
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    FocusScope.of(context).unfocus();
    final listId = extractPlaylistId(url);
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _playlist = null;
      _clipLink = null;
      _custom = false;
      _linkedPlaylistId = null;
      _isShort = url.contains('/shorts/');
    });
    try {
      if (listId != null && isPlaylistOnlyLink(url)) {
        await _loadPlaylistInner(listId);
      } else {
        final info = await manager.fetch(normalizeYoutubeInput(url));
        final vs = sortedVideos(info.manifest);
        final tracks = groupTracks(info.manifest);
        final tr = defaultTrack(tracks); // original language by default
        if (!mounted) return;
        setState(() {
          _info = info;
          _videos = vs;
          _tracks = tracks;
          _track = tr;
          _v = vs.firstOrNull;
          _a = tr?.streams.firstOrNull;
          _linkedPlaylistId = listId;
          _mode = settings.defaultPreset == QualityPreset.audio
              ? Mode.audioOnly
              : Mode.both;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadPlaylist(String id) async {
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _playlist = null;
    });
    try {
      await _loadPlaylistInner(id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadPlaylistInner(String id) async {
    final pl = await manager.fetchPlaylist(id);
    if (!mounted) return;
    setState(() {
      _playlist = pl;
      _sel
        ..clear()
        ..addAll(pl.videos.map((v) => v.id.value));
      _batchPreset = settings.defaultPreset;
    });
  }

  void _toast(String msg) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      action: SnackBarAction(label: 'VIEW', onPressed: widget.onQueued),
    ));
  }

  void _enqueue({VideoOnlyStreamInfo? v, AudioOnlyStreamInfo? a}) {
    final info = _info;
    if (info == null || (v == null && a == null)) return;
    manager.enqueue(DownloadRequest(info.video, videoStream: v, audioStream: a));
    if (settings.haptics) HapticFeedback.mediumImpact();
    _toast('Added to downloads');
  }

  void _downloadPlaylist() {
    final pl = _playlist;
    if (pl == null) return;
    final vids = pl.videos.where((v) => _sel.contains(v.id.value)).toList();
    if (vids.isEmpty) return;
    manager.enqueueBatch(vids, _batchPreset);
    if (settings.haptics) HapticFeedback.mediumImpact();
    _toast('${vids.length} video${vids.length == 1 ? '' : 's'} queued');
  }

  // ---------- audio language ----------

  String _trackLabel(AudioTrackGroup t) {
    final n = t.name.isEmpty ? 'Unknown language' : t.name;
    return t == _defaultTrack ? '$n · default' : n;
  }

  AudioOnlyStreamInfo? _nearest(
      List<AudioOnlyStreamInfo> list, AudioOnlyStreamInfo? prev) {
    if (list.isEmpty) return null;
    if (prev == null) return list.first;
    final same = list.where((s) => s.container.name == prev.container.name);
    final pool = [...(same.isEmpty ? list : same)];
    final target = prev.bitrate.bitsPerSecond;
    pool.sort((x, y) => (x.bitrate.bitsPerSecond - target)
        .abs()
        .compareTo((y.bitrate.bitsPerSecond - target).abs()));
    return pool.first;
  }

  void _pickTrack(AudioTrackGroup g) {
    setState(() {
      final prev = _a;
      _track = g;
      _a = _nearest(g.streams, prev);
    });
  }

  void _showTrackSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('Audio language',
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final t in _tracks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                selected: t == _track,
                leading: Icon(t == _track
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off),
                title: Text(_trackLabel(t)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickTrack(t);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ---------- custom selection helpers ----------

  VideoOnlyStreamInfo? get _customVideo => _mode == Mode.audioOnly ? null : _v;
  AudioOnlyStreamInfo? get _customAudio => _mode == Mode.videoOnly ? null : _a;

  int get _estimate =>
      (_customVideo?.size.totalBytes ?? 0) +
      (_customAudio?.size.totalBytes ?? 0);

  bool get _willBeMkv {
    final v = _customVideo;
    final a = _customAudio;
    if (v == null || a == null) return false;
    return !(v.container.name == 'mp4' && a.container.name == 'mp4');
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _inputCard(),
        if (_clipLink != null && !_loading) _clipChip(),
        if (_loading) _loadingCard(),
        if (_error != null) _errorCard(),
        if (_info == null && _playlist == null && !_loading && _error == null)
          _hero(),
        if (_info != null) ..._results(),
        if (_playlist != null) ..._playlistSection(),
      ],
    );
  }

  Widget _inputCard() {
    return SoftCard(
      child: Column(children: [
        TextField(
          controller: _ctrl,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _fetch(),
          decoration: InputDecoration(
            hintText: 'Paste a video, Shorts or playlist link',
            prefixIcon: const Icon(Icons.link),
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: 'Paste and fetch',
                    onPressed: _paste,
                  )
                : IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear',
                    onPressed: () => setState(() {
                      _ctrl.clear();
                      _info = null;
                      _playlist = null;
                      _error = null;
                    }),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _loading ? 'Reading…' : 'Fetch',
            icon: Icons.search,
            busy: _loading,
            onPressed: _ctrl.text.trim().isEmpty ? null : () => _fetch(),
          ),
        ),
      ]),
    );
  }

  Widget _clipChip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          avatar: const Icon(Icons.content_paste_go, size: 18),
          label: const Text('Link in clipboard · tap to fetch'),
          onPressed: () => _fetch(_clipLink),
        ),
      ),
    );
  }

  Widget _loadingCard() {
    return const SoftCard(
      child: Column(children: [
        LinearProgressIndicator(),
        SizedBox(height: 12),
        Text('Reading from YouTube…'),
      ]),
    );
  }

  Widget _errorCard() {
    final cs = Theme.of(context).colorScheme;
    return SoftCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.error_outline, color: cs.error),
          const SizedBox(width: 8),
          Text('Could not load this link',
              style: TextStyle(color: cs.error, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Text(_error!),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _fetch(),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ),
      ]),
    );
  }

  Widget _hero() {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(children: [
        Image.asset('assets/logo.png', height: 150),
        const SizedBox(height: 14),
        Text('Save videos in full quality',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Paste a link, or share one straight from YouTube.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill('8K · 4K · 1080p', icon: Icons.hd),
            Pill('Playlists', icon: Icons.playlist_play),
            Pill('Audio only', icon: Icons.music_note),
            Pill('Shorts', icon: Icons.bolt),
            Pill('Share to app', icon: Icons.share),
            Pill('Background', icon: Icons.cloud_download_outlined),
          ],
        ),
      ]),
    );
  }

  // ---------- single video ----------

  List<Widget> _results() {
    final cs = Theme.of(context).colorScheme;
    final v = _info!.video;
    final up = v.uploadDate;
    final picks = <QualityPreset, PresetPick>{};
    for (final p in QualityPreset.values) {
      final pick = pickPreset(p, _videos, _audios);
      if (!pick.valid) continue;
      final dup = picks.values
          .any((q) => q.video == pick.video && q.audio == pick.audio);
      if (!dup) picks[p] = pick;
    }
    final def = pickPreset(settings.defaultPreset, _videos, _audios);

    return [
      SoftCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoThumb(
              url: v.thumbnails.highResUrl,
              radius: 14,
              badge: v.duration == null ? 'LIVE' : fmtDuration(v.duration!),
            ),
          ),
          const SizedBox(height: 12),
          Text(v.title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (_isShort)
              const Pill('Shorts', icon: Icons.bolt, color: Colors.redAccent),
            Pill(v.author, icon: Icons.person_outline),
            Pill('${fmtCount(v.engagement.viewCount)} views',
                icon: Icons.visibility_outlined),
            if (up != null) Pill(fmtDate(up), icon: Icons.calendar_today_outlined),
          ]),
        ]),
      ),
      if (_linkedPlaylistId != null)
        SoftCard(
          onTap: () => _loadPlaylist(_linkedPlaylistId!),
          child: Row(children: [
            Icon(Icons.playlist_play, color: cs.primary, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Part of a playlist',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text('Tap to pick videos and download them all',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      if (_tracks.length > 1 && _track != null)
        SoftCard(
          onTap: _showTrackSheet,
          child: Row(children: [
            Icon(Icons.translate, color: cs.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Audio language',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(_trackLabel(_track!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            Text('${_tracks.length} tracks',
                style: Theme.of(context).textTheme.bodySmall),
            const Icon(Icons.chevron_right),
          ]),
        ),
      const SectionTitle('Quick download'),
      for (final e in picks.entries)
        _presetTile(
          e.key,
          e.value,
          e.value.video == def.video && e.value.audio == def.audio,
        ),
      const SizedBox(height: 4),
      _customCard(),
    ];
  }

  Widget _presetTile(QualityPreset p, PresetPick pick, bool isDefault) {
    final cs = Theme.of(context).colorScheme;
    return SoftCard(
      highlight: isDefault,
      onTap: () => _enqueue(v: pick.video, a: pick.audio),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
              gradient: brandGradient, shape: BoxShape.circle),
          child: Icon(p.icon, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(p.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (isDefault) ...[
                const SizedBox(width: 6),
                const Pill('Default'),
              ],
            ]),
            const SizedBox(height: 2),
            Text(pickSummary(pick),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(fmtBytes(pick.bytes),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Icon(Icons.download_rounded, color: cs.primary),
        ]),
      ]),
    );
  }

  Widget _customCard() {
    return SoftCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _custom = !_custom),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              const Icon(Icons.tune),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Customize quality',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Icon(_custom ? Icons.expand_less : Icons.expand_more),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child: _custom
              ? _customBody()
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }

  Widget _customBody() {
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      SegmentedButton<Mode>(
        segments: const [
          ButtonSegment(value: Mode.both, label: Text('Video+Audio')),
          ButtonSegment(value: Mode.videoOnly, label: Text('Video')),
          ButtonSegment(value: Mode.audioOnly, label: Text('Audio')),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
      if (_mode != Mode.audioOnly) ...[
        const SizedBox(height: 14),
        Text('Video', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final s in _videos)
            ChoiceChip(
              label: Text('${s.qualityLabel} · ${vcodecName(s.videoCodec)}'),
              selected: s == _v,
              onSelected: (_) => setState(() => _v = s),
            ),
        ]),
        if (_v != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(describeVideo(_v!), style: small),
          ),
      ],
      if (_mode != Mode.videoOnly) ...[
        if (_tracks.length > 1) ...[
          const SizedBox(height: 14),
          Text('Audio language', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final t in _tracks)
              ChoiceChip(
                avatar: t == _defaultTrack
                    ? const Icon(Icons.star, size: 16)
                    : null,
                label: Text(t.name.isEmpty ? 'Unknown' : t.name),
                selected: t == _track,
                onSelected: (_) => _pickTrack(t),
              ),
          ]),
        ],
        const SizedBox(height: 14),
        Text('Audio quality', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final s in _audios)
            ChoiceChip(
              label: Text(
                  '${acodecName(s.audioCodec)} ${s.bitrate.kiloBitsPerSecond.round()}k'),
              selected: s == _a,
              onSelected: (_) => setState(() => _a = s),
            ),
        ]),
        if (_a != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(describeAudio(_a!), style: small),
          ),
      ],
      if (_willBeMkv)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'This combination is saved as MKV. Pick H.264 + AAC (mp4) '
                'if you need it to play in every gallery app.',
                style: small,
              ),
            ),
          ]),
        ),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: GradientButton(
          label: 'Download · ${fmtBytes(_estimate)}',
          icon: Icons.download_rounded,
          onPressed: (_customVideo == null && _customAudio == null)
              ? null
              : () => _enqueue(v: _customVideo, a: _customAudio),
        ),
      ),
    ]);
  }

  // ---------- playlist ----------

  List<Widget> _playlistSection() {
    final cs = Theme.of(context).colorScheme;
    final pl = _playlist!;
    final n = _sel.length;
    return [
      SoftCard(
        child: Row(children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
                gradient: brandGradient, shape: BoxShape.circle),
            child: const Icon(Icons.playlist_play, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pl.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                Pill('${pl.videos.length} videos',
                    icon: Icons.video_library_outlined),
                if (pl.author.isNotEmpty)
                  Pill(pl.author, icon: Icons.person_outline, color: cs.secondary),
              ]),
            ]),
          ),
        ]),
      ),
      const SectionTitle('Quality for all videos'),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final p in QualityPreset.values)
          ChoiceChip(
            avatar: Icon(p.icon, size: 16),
            label: Text(p.title),
            selected: _batchPreset == p,
            onSelected: (_) => setState(() => _batchPreset = p),
          ),
      ]),
      const SizedBox(height: 12),
      GradientButton(
        label: n == 0
            ? 'Select videos to download'
            : 'Download $n video${n == 1 ? '' : 's'}',
        icon: Icons.download_rounded,
        onPressed: n == 0 ? null : _downloadPlaylist,
      ),
      const SizedBox(height: 8),
      Text(
        'Original-language audio is used. Videos are prepared one at a time '
        'to stay under YouTube\'s rate limits.',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: SectionTitle('Videos')),
        TextButton(
          onPressed: () => setState(() => _sel
            ..clear()
            ..addAll(pl.videos.map((v) => v.id.value))),
          child: const Text('All'),
        ),
        TextButton(
          onPressed: () => setState(_sel.clear),
          child: const Text('None'),
        ),
      ]),
      for (final v in pl.videos) _playlistRow(v),
    ];
  }

  Widget _playlistRow(Video v) {
    final id = v.id.value;
    final on = _sel.contains(id);
    void toggle() => setState(() {
          if (on) {
            _sel.remove(id);
          } else {
            _sel.add(id);
          }
        });
    return SoftCard(
      padding: const EdgeInsets.all(10),
      onTap: toggle,
      child: Row(children: [
        Checkbox(value: on, onChanged: (_) => toggle()),
        VideoThumb(
          url: v.thumbnails.lowResUrl,
          width: 84,
          height: 50,
          radius: 10,
          badge: v.duration == null ? null : fmtDuration(v.duration!),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(v.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}