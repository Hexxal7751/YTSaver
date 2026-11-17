import 'dart:io';

import 'package:flutter/material.dart';

import '../download_manager.dart';
import '../models.dart';
import '../native.dart';
import '../open_helper.dart';
import '../settings.dart';
import '../theme.dart';
import 'widgets.dart';

enum _Filter { all, active, done, failed }

enum _Sort { newest, oldest, largest, smallest, name }

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});
  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  _Filter _f = _Filter.all;
  _Sort _sort = _Sort.newest;
  bool _searching = false;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _match(DownloadTask t, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.active => t.active,
        _Filter.done => t.state == TaskState.done,
        _Filter.failed =>
          t.state == TaskState.failed || t.state == TaskState.cancelled,
      };

  String _name(_Filter f) => switch (f) {
        _Filter.all => 'All',
        _Filter.active => 'Active',
        _Filter.done => 'Done',
        _Filter.failed => 'Failed',
      };

  String _sortName(_Sort s) => switch (s) {
        _Sort.newest => 'Newest first',
        _Sort.oldest => 'Oldest first',
        _Sort.largest => 'Largest first',
        _Sort.smallest => 'Smallest first',
        _Sort.name => 'Name (A-Z)',
      };

  int _size(DownloadTask t) => t.fileBytes ?? t.total;

  /// Filtered + searched + sorted list (active downloads stay on top).
  List<DownloadTask> _view(List<DownloadTask> all) {
    final q = _query.trim().toLowerCase();
    final list = all.where((t) {
      if (!_match(t, _f)) return false;
      if (q.isEmpty) return true;
      return t.title.toLowerCase().contains(q) ||
          (t.channel ?? '').toLowerCase().contains(q) ||
          t.label.toLowerCase().contains(q);
    }).toList();
    final active = list.where((t) => t.active).toList();
    final rest = list.where((t) => !t.active).toList();
    rest.sort((a, b) => switch (_sort) {
          _Sort.newest => b.createdAt.compareTo(a.createdAt),
          _Sort.oldest => a.createdAt.compareTo(b.createdAt),
          _Sort.largest => _size(b).compareTo(_size(a)),
          _Sort.smallest => _size(a).compareTo(_size(b)),
          _Sort.name => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        });
    return [...active, ...rest];
  }

  void _showQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _QueueSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final all = manager.tasks;
        if (all.isEmpty) return _empty(context);
        final shown = _view(all);
        final hasFinished = all.any((t) => !t.active);
        return Column(children: [
          const _Summary(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: _searching ? _searchField() : _filterRow(all, hasFinished),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(_query.trim().isEmpty
                        ? 'Nothing here'
                        : 'No matches for "${_query.trim()}"'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final t = shown[i];
                      return Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.delete_sweep_outlined),
                        ),
                        onDismissed: (_) => manager.remove(t),
                        child: _TaskCard(task: t),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchCtrl,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: (v) => setState(() => _query = v),
      decoration: InputDecoration(
        hintText: 'Search title, channel or quality',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close search',
          onPressed: () => setState(() {
            _searching = false;
            _query = '';
            _searchCtrl.clear();
          }),
        ),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _filterRow(List<DownloadTask> all, bool hasFinished) {
    final queued = manager.queuedTasks.length;
    return Row(children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in _Filter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                      '${_name(f)} (${all.where((t) => _match(t, f)).length})'),
                  selected: _f == f,
                  onSelected: (_) => setState(() => _f = f),
                ),
              ),
          ]),
        ),
      ),
      Badge(
        isLabelVisible: queued > 0,
        label: Text('$queued'),
        child: IconButton(
          tooltip: 'Queue',
          icon: const Icon(Icons.low_priority),
          onPressed: _showQueue,
        ),
      ),
      IconButton(
        tooltip: 'Search',
        icon: const Icon(Icons.search),
        onPressed: () => setState(() => _searching = true),
      ),
      PopupMenuButton<_Sort>(
        tooltip: 'Sort',
        icon: const Icon(Icons.sort),
        initialValue: _sort,
        onSelected: (s) => setState(() => _sort = s),
        itemBuilder: (_) => [
          for (final s in _Sort.values)
            CheckedPopupMenuItem<_Sort>(
              value: s,
              checked: _sort == s,
              child: Text(_sortName(s)),
            ),
        ],
      ),
      if (hasFinished)
        IconButton(
          tooltip: 'Clear finished',
          icon: const Icon(Icons.cleaning_services_outlined),
          onPressed: manager.clearFinished,
        ),
    ]);
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset('assets/logo.png', height: 120),
        const SizedBox(height: 12),
        Text('No downloads yet',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Paste a link in the Get tab to start'),
      ]),
    );
  }
}

/// Queue: set how many downloads run at once and drag to reorder the rest.
class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: ListenableBuilder(
          listenable: Listenable.merge([manager, settings]),
          builder: (context, _) {
            final q = manager.queuedTasks;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Queue',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text('Downloads at the same time',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    for (final n in const [1, 2, 3, 4])
                      ChoiceChip(
                        label: Text('$n'),
                        selected: settings.maxConcurrent == n,
                        onSelected: (_) => manager.setMaxConcurrent(n),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    q.isEmpty
                        ? 'Nothing is waiting.'
                        : 'Drag to reorder. The top one starts next.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]),
              ),
              Expanded(
                child: q.isEmpty
                    ? const SizedBox.shrink()
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: q.length,
                        onReorder: (o, n) {
                          if (n > o) n -= 1;
                          manager.moveQueued(o, n);
                        },
                        itemBuilder: (c, i) {
                          final t = q[i];
                          return ListTile(
                            key: ValueKey(t.id),
                            leading: ReorderableDragStartListener(
                              index: i,
                              child: const Icon(Icons.drag_handle),
                            ),
                            title: Text(t.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text('#${i + 1} · ${t.label}'),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                tooltip: 'Start now',
                                icon: const Icon(Icons.play_arrow),
                                onPressed: () => manager.startNow(t),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close),
                                onPressed: () => manager.remove(t),
                              ),
                            ]),
                          );
                        },
                      ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Banner with active count, total speed and overall progress.
class _Summary extends StatelessWidget {
  const _Summary();

  @override
  Widget build(BuildContext context) {
    final active = manager.tasks.where((t) => t.active).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge(active),
      builder: (context, _) {
        final speed = active.fold<double>(
            0, (s, t) => s + (t.state == TaskState.downloading ? t.speed : 0));
        final rec = active.fold<int>(0, (s, t) => s + t.received);
        final tot = active.fold<int>(0, (s, t) => s + t.total);
        final merging = active.every((t) => t.state == TaskState.merging);
        final waiting = active.every((t) => t.state == TaskState.waitingWifi);
        final paused = active.every((t) => t.state == TaskState.paused);
        final queued = active.every((t) => t.state == TaskState.queued);
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: brandGradient,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.cloud_download_outlined, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${active.length} active download${active.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16),
                ),
              ),
              Text(
                  paused
                      ? 'Paused'
                      : waiting
                          ? 'Waiting for Wi-Fi'
                          : queued
                              ? 'Waiting…'
                              : merging
                                  ? 'Processing…'
                                  : '${fmtBytes(speed)}/s',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (tot == 0 || merging || waiting || queued)
                    ? (paused && tot > 0 ? rec / tot : null)
                    : rec / tot,
                minHeight: 7,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});
  final DownloadTask task;

  Future<void> _confirmDelete(BuildContext context, DownloadTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('"${t.title}" will be removed from your phone.'),
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
    if (ok == true) await manager.deleteWithFile(t);
  }

  Future<void> _play(BuildContext context, String path) async {
    final ok = await Native.openFile(path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app found to play this file')),
      );
    }
  }

  Future<void> _share(BuildContext context, DownloadTask t, String path) async {
    final ok = await Native.shareFile(path, title: t.title);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not share this file')),
      );
    }
  }

  Widget _thumb(DownloadTask t) {
    Widget? overlay;
    if (t.active) {
      final determinate = t.state == TaskState.downloading;
      Widget center;
      switch (t.state) {
        case TaskState.waitingWifi:
          center = const Icon(Icons.wifi, color: Colors.white);
        case TaskState.queued:
          center = const Icon(Icons.schedule, color: Colors.white);
        case TaskState.paused:
          center = const Icon(Icons.pause, color: Colors.white);
        default:
          center = SizedBox(
            width: 34,
            height: 34,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: determinate ? t.progress : null,
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
              if (determinate)
                Text('${(t.progress * 100).round()}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
            ]),
          );
      }
      overlay = Container(color: Colors.black54, child: Center(child: center));
    }
    return VideoThumb(
      url: t.thumbnailUrl,
      width: 104,
      height: 62,
      radius: 12,
      badge: t.videoDuration == null ? null : fmtDuration(t.videoDuration!),
      overlay: overlay,
    );
  }

  Widget _body(BuildContext context, DownloadTask t) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme.bodySmall;
    switch (t.state) {
      case TaskState.queued:
        {
          final pos = manager.queuePosition(t);
          return Row(children: [
            Icon(Icons.schedule, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(pos > 0 ? 'Waiting in queue · #$pos' : 'Starting…',
                  style: tt),
            ),
            if (pos > 0)
              TextButton(
                onPressed: () => manager.startNow(t),
                child: const Text('Start now'),
              ),
          ]);
        }
      case TaskState.waitingWifi:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.wifi, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(child: Text('Waiting for Wi-Fi…', style: tt)),
          ]),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () {
              t.forceMobile = true;
              t.touch();
            },
            icon: const Icon(Icons.signal_cellular_alt),
            label: const Text('Use mobile data'),
          ),
        ]);
      case TaskState.downloading:
        {
          final eta = t.eta;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: t.progress, minHeight: 7),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Text('${(t.progress * 100).round()}%',
                  style: tt?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              Text('${fmtBytes(t.speed)}/s',
                  style: tt?.copyWith(fontWeight: FontWeight.w600)),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Pause',
                icon: const Icon(Icons.pause_circle_outline),
                onPressed: () => manager.pause(t),
              ),
            ]),
            Text(
              '${fmtBytes(t.received)} / ${fmtBytes(t.total)} · '
              'ETA ${eta == null ? '--' : fmtDuration(eta)}',
              style: tt,
            ),
            if (t.status != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Icon(Icons.sync_problem, size: 16, color: cs.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(t.status!,
                        style: tt?.copyWith(color: cs.tertiary)),
                  ),
                ]),
              ),
          ]);
        }
      case TaskState.paused:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: t.progress, minHeight: 7),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.pause_circle, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Paused · ${(t.progress * 100).round()}% · '
                '${fmtBytes(t.received)} / ${fmtBytes(t.total)}',
                style: tt,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () => manager.resume(t),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Resume'),
            ),
          ]),
        ]);
      case TaskState.merging:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: const LinearProgressIndicator(minHeight: 7),
          ),
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('Processing…', style: tt),
          ]),
        ]);
      case TaskState.done:
        {
          final p = t.outputPath;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                t.note == null ? Icons.check_circle : Icons.warning_amber,
                size: 18,
                color: t.note == null ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.note ??
                      'Saved · ${t.fileBytes == null ? '' : '${fmtBytes(t.fileBytes!)} · '}'
                          '${timeAgo(t.createdAt)}',
                  style: tt,
                ),
              ),
            ]),
            if (p != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(
                    child: Wrap(spacing: 8, runSpacing: 6, children: [
                      FilledButton.icon(
                        onPressed: () => _play(context, p),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _share(context, t, p),
                        icon: const Icon(Icons.share),
                        label: const Text('Share'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => openFolderWithFeedback(
                            context, File(p).parent.path),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Folder'),
                      ),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Delete file',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(context, t),
                  ),
                ]),
              ),
          ]);
        }
      case TaskState.failed:
      case TaskState.cancelled:
        {
          final failed = t.state == TaskState.failed;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(failed ? Icons.error_outline : Icons.cancel_outlined,
                  size: 18, color: failed ? cs.error : cs.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  failed ? (t.error ?? 'Failed') : 'Cancelled',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: tt?.copyWith(color: failed ? cs.error : null),
                ),
              ),
            ]),
            if (t.retryPayload != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonalIcon(
                  onPressed: () => manager.retry(t),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
          ]);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final t = task;
        final cs = Theme.of(context).colorScheme;
        return SoftCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _thumb(t),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    Pill(t.label,
                        icon: t.audioOnly
                            ? Icons.music_note
                            : Icons.movie_outlined),
                    if (t.channel != null && t.channel!.isNotEmpty)
                      Pill(t.channel!, color: cs.secondary),
                  ]),
                ]),
              ),
              if (t.active)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.close),
                  onPressed: () => manager.cancel(t),
                ),
            ]),
            const SizedBox(height: 12),
            _body(context, t),
            if (t.logs.isNotEmpty)
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Details · log (${t.logs.length})',
                      style: Theme.of(context).textTheme.bodySmall),
                  children: [
                    Container(
                      height: 160,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                          t.logs.join('\n'),
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.greenAccent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        );
      },
    );
  }
}