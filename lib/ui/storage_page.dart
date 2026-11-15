import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../download_manager.dart';
import '../models.dart';
import '../open_helper.dart';
import 'widgets.dart';

class _Usage {
  _Usage(this.files, this.bytes);
  final List<File> files;
  final int bytes;
}

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});
  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  bool _loading = true;
  _Usage? _video;
  _Usage? _audio;
  int _cache = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<_Usage> _scanDir(String path) async {
    final files = <File>[];
    var total = 0;
    try {
      final d = Directory(path);
      if (await d.exists()) {
        await for (final e in d.list(followLinks: false)) {
          if (e is File) {
            files.add(e);
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return _Usage(files, total);
  }

  Future<int> _dirSize(Directory d) async {
    var n = 0;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            n += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    final v = await _scanDir(videoDir);
    final a = await _scanDir(audioDir);
    final c = await _dirSize(await getTemporaryDirectory());
    if (!mounted) return;
    setState(() {
      _video = v;
      _audio = a;
      _cache = c;
      _loading = false;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool?> _confirm(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _deleteFiles(List<File> files, int bytes) async {
    for (final f in files) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await manager.pruneMissing();
    await _scan();
    _snack('Freed ${fmtBytes(bytes)}');
  }

  Future<void> _clearCache() async {
    if (manager.tasks.any((t) => t.active)) {
      _snack('Wait until the current downloads finish');
      return;
    }
    final before = _cache;
    try {
      final d = await getTemporaryDirectory();
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    await _scan();
    _snack('Freed ${fmtBytes(before)}');
  }

  Future<void> _deleteOlder() async {
    final days = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Delete files older than'),
        children: [
          for (final d in const [7, 30, 90, 180])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, d),
              child: Text('$d days'),
            ),
        ],
      ),
    );
    if (days == null) return;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final victims = <File>[];
    var bytes = 0;
    for (final f in [...?_video?.files, ...?_audio?.files]) {
      try {
        final st = await f.stat();
        if (st.modified.isBefore(cutoff)) {
          victims.add(f);
          bytes += st.size;
        }
      } catch (_) {}
    }
    if (victims.isEmpty) {
      _snack('Nothing older than $days days');
      return;
    }
    final ok = await _confirm('Delete ${victims.length} file(s)?',
        '${fmtBytes(bytes)} will be freed.');
    if (ok == true) await _deleteFiles(victims, bytes);
  }

  Future<void> _deleteAll() async {
    final files = [...?_video?.files, ...?_audio?.files];
    final bytes = (_video?.bytes ?? 0) + (_audio?.bytes ?? 0);
    if (files.isEmpty) {
      _snack('No files to delete');
      return;
    }
    final ok = await _confirm('Delete ALL downloads?',
        '${files.length} file(s), ${fmtBytes(bytes)}, in:\n$videoDir\n$audioDir');
    if (ok == true) await _deleteFiles(files, bytes);
  }

  Widget _bar(int v, int a, int c) {
    final cs = Theme.of(context).colorScheme;
    final total = v + a + c;
    int flex(int x) => (x * 1000 / total).round().clamp(1, 1000);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 12,
        child: total == 0
            ? Container(color: cs.surfaceContainerHighest)
            : Row(children: [
                if (v > 0)
                  Expanded(flex: flex(v), child: Container(color: cs.primary)),
                if (a > 0)
                  Expanded(flex: flex(a), child: Container(color: cs.tertiary)),
                if (c > 0)
                  Expanded(flex: flex(c), child: Container(color: cs.outline)),
              ]),
      ),
    );
  }

  Widget _legend(Color color, String name, String detail, int bytes) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        Text(fmtBytes(bytes),
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = _video;
    final a = _audio;
    final vb = v?.bytes ?? 0;
    final ab = a?.bytes ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _scan,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SoftCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(fmtBytes(vb + ab),
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const Text('used by your downloads'),
                    const SizedBox(height: 14),
                    _bar(vb, ab, _cache),
                    const SizedBox(height: 8),
                    _legend(cs.primary, 'Videos',
                        '${v?.files.length ?? 0} files', vb),
                    _legend(cs.tertiary, 'Audio',
                        '${a?.files.length ?? 0} files', ab),
                    _legend(cs.outline, 'Temporary cache',
                        'Leftovers from interrupted downloads', _cache),
                  ]),
                ),
                const SectionTitle('Clean up'),
                SoftCard(
                  onTap: _clearCache,
                  child: const Row(children: [
                    Icon(Icons.cleaning_services_outlined),
                    SizedBox(width: 12),
                    Expanded(child: Text('Clear cache')),
                    Icon(Icons.chevron_right),
                  ]),
                ),
                SoftCard(
                  onTap: _deleteOlder,
                  child: const Row(children: [
                    Icon(Icons.event_busy_outlined),
                    SizedBox(width: 12),
                    Expanded(child: Text('Delete files older than…')),
                    Icon(Icons.chevron_right),
                  ]),
                ),
                SoftCard(
                  onTap: () async {
                    await manager.pruneMissing();
                    _snack('History cleaned');
                  },
                  child: const Row(children: [
                    Icon(Icons.history_toggle_off),
                    SizedBox(width: 12),
                    Expanded(child: Text('Remove missing files from history')),
                    Icon(Icons.chevron_right),
                  ]),
                ),
                SoftCard(
                  onTap: _deleteAll,
                  child: Row(children: [
                    Icon(Icons.delete_forever_outlined, color: cs.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Delete all downloads',
                          style: TextStyle(color: cs.error)),
                    ),
                    const Icon(Icons.chevron_right),
                  ]),
                ),
                const SizedBox(height: 4),
                Text(
                  'On newer Android versions YTSaver can only see files it '
                  'created itself.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
    );
  }
}