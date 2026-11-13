import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../download_manager.dart';
import '../links.dart';
import '../models.dart';
import '../presets.dart';
import '../settings.dart';
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
  VideoInfo? _info;
  List<VideoOnlyStreamInfo> _videos = [];
  List<AudioOnlyStreamInfo> _audios = [];
  VideoOnlyStreamInfo? _v;
  AudioOnlyStreamInfo? _a;
  Mode _mode = Mode.both;
  bool _loading = false;
  bool _isShort = false;
  bool _custom = false;
  String? _error;
  String? _clipLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
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
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _clipLink = null;
      _custom = false;
      _isShort = url.contains('/shorts/');
    });
    try {
      final info = await manager.fetch(normalizeYoutubeInput(url));
      final vs = [...info.manifest.videoOnly]..sort((x, y) {
          final h = y.videoResolution.height.compareTo(x.videoResolution.height);
          if (h != 0) return h;
          final f = y.framerate.framesPerSecond
              .compareTo(x.framerate.framesPerSecond);
          if (f != 0) return f;
          return y.bitrate.bitsPerSecond.compareTo(x.bitrate.bitsPerSecond);
        });
      final aus = [...info.manifest.audioOnly]..sort(
          (x, y) => y.bitrate.bitsPerSecond.compareTo(x.bitrate.bitsPerSecond));
      setState(() {
        _info = info;
        _videos = vs;
        _audios = aus;
        _v = vs.firstOrNull;
        _a = aus.firstOrNull;
        _mode = settings.defaultPreset == QualityPreset.audio
            ? Mode.audioOnly
            : Mode.both;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _enqueue({VideoOnlyStreamInfo? v, AudioOnlyStreamInfo? a}) {
    final info = _info;
    if (info == null || (v == null && a == null)) return;
    manager.enqueue(DownloadRequest(info.video, videoStream: v, audioStream: a));
    if (settings.haptics) HapticFeedback.mediumImpact();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: const Text('Added to downloads'),
      action: SnackBarAction(label: 'VIEW', onPressed: widget.onQueued),
    ));
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
        if (_info == null && !_loading && _error == null) _hero(),
        if (_info != null) ..._results(),
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
            hintText: 'Paste a YouTube or Shorts link',
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
                      _error = null;
                    }),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _loading ? 'Reading video…' : 'Fetch formats',
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
        Text('Reading available qualities…'),
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
          Text('Could not load this video',
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
        Text('Paste a link above, pick a quality, done.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill('8K · 4K · 1080p', icon: Icons.hd),
            Pill('Audio only', icon: Icons.music_note),
            Pill('Shorts', icon: Icons.bolt),
            Pill('Background', icon: Icons.cloud_download_outlined),
          ],
        ),
      ]),
    );
  }

  List<Widget> _results() {
    final v = _info!.video;
    final up = v.uploadDate;
    final picks = <QualityPreset, PresetPick>{};
    for (final p in QualityPreset.values) {
      final pick = pickPreset(p, _videos, _audios);
      if (!pick.valid) continue;
      final dup = picks.values.any((q) => q.video == pick.video && q.audio == pick.audio);
      if (!dup) picks[p] = pick;
    }
    final def = pickPreset(settings.defaultPreset, _videos, _audios);

    return [
      // video card
      SoftCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Thumb(
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
        const SizedBox(height: 14),
        Text('Audio', style: Theme.of(context).textTheme.labelLarge),
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
}