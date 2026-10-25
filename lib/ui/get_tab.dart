import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../download_manager.dart';
import '../models.dart';

enum Mode { both, videoOnly, audioOnly }

class GetTab extends StatefulWidget {
  const GetTab({super.key, required this.onQueued});
  final VoidCallback onQueued;
  @override
  State<GetTab> createState() => _GetTabState();
}

class _GetTabState extends State<GetTab> {
  final _ctrl = TextEditingController();
  VideoInfo? _info;
  List<VideoOnlyStreamInfo> _videos = [];
  List<AudioOnlyStreamInfo> _audios = [];
  VideoOnlyStreamInfo? _v;
  AudioOnlyStreamInfo? _a;
  Mode _mode = Mode.both;
  bool _loading = false;
  String? _error;

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) {
      _ctrl.text = d!.text!.trim();
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      final info = await manager.fetch(url);
      final vs = [...info.manifest.videoOnly]..sort((x, y) {
          final h = y.videoResolution.height.compareTo(x.videoResolution.height);
          if (h != 0) return h;
          final f = y.framerate.framesPerSecond
              .compareTo(x.framerate.framesPerSecond);
          if (f != 0) return f;
          return y.bitrate.bitsPerSecond.compareTo(x.bitrate.bitsPerSecond);
        });
      final as = [...info.manifest.audioOnly]..sort(
          (x, y) => y.bitrate.bitsPerSecond.compareTo(x.bitrate.bitsPerSecond));
      setState(() {
        _info = info;
        _videos = vs;
        _audios = as;
        _v = vs.firstOrNull;
        _a = as.firstOrNull;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  int get _estimate =>
      (_mode != Mode.audioOnly ? (_v?.size.totalBytes ?? 0) : 0) +
      (_mode != Mode.videoOnly ? (_a?.size.totalBytes ?? 0) : 0);

  void _download() {
    final info = _info;
    if (info == null) return;
    manager.enqueue(DownloadRequest(
      info.video,
      videoStream: _mode == Mode.audioOnly ? null : _v,
      audioStream: _mode == Mode.videoOnly ? null : _a,
    ));
    widget.onQueued();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            labelText: 'Video link',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
                icon: const Icon(Icons.paste), onPressed: _paste),
          ),
          onSubmitted: (_) => _fetch(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _loading ? null : _fetch,
          icon: const Icon(Icons.search),
          label: Text(_loading ? 'Loading…' : 'Fetch formats'),
        ),
        if (_loading) const Padding(
          padding: EdgeInsets.only(top: 16),
          child: LinearProgressIndicator(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: TextStyle(color: cs.error)),
          ),
        if (_info != null) ..._details(cs),
      ],
    );
  }

  List<Widget> _details(ColorScheme cs) {
    final v = _info!.video;
    return [
      const SizedBox(height: 16),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Image.network(v.thumbnails.highResUrl,
              width: double.infinity, height: 190, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(height: 190)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${v.author} · ${v.duration == null ? 'live' : fmtDuration(v.duration!)}'),
            ]),
          ),
        ]),
      ),
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
        _header('Video quality'),
        for (final s in _videos)
          ListTile(
            dense: true,
            selected: s == _v,
            leading: Icon(s == _v ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(describeVideo(s)),
            onTap: () => setState(() => _v = s),
          ),
      ],
      if (_mode != Mode.videoOnly) ...[
        _header('Audio quality'),
        for (final s in _audios)
          ListTile(
            dense: true,
            selected: s == _a,
            leading: Icon(s == _a ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(describeAudio(s)),
            onTap: () => setState(() => _a = s),
          ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _download,
        icon: const Icon(Icons.download),
        label: Text('Download (${fmtBytes(_estimate)})'),
      ),
    ];
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall),
      );
}
