import 'dart:io';

import 'package:flutter/material.dart';

import '../download_manager.dart';
import '../models.dart';
import '../open_helper.dart';
import '../theme.dart';
import 'widgets.dart';

enum _Filter { all, active, done, failed }

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});
  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  _Filter _f = _Filter.all;

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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final all = manager.tasks;
        if (all.isEmpty) return _empty(context);
        final shown = all.where((t) => _match(t, _f)).toList();
        final hasFinished = all.any((t) => !t.active);
        return Column(children: [
          const _Summary(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(children: [
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
              if (hasFinished)
                IconButton(
                  tooltip: 'Clear finished',
                  icon: const Icon(Icons.cleaning_services_outlined),
                  onPressed: manager.clearFinished,
                ),
            ]),
          ),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('Nothing here'))
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
              Text(merging ? 'Merging…' : '${fmtBytes(speed)}/s',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (tot == 0 || merging) ? null : rec / tot,
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

  Widget _thumb(DownloadTask t) {
    Widget? overlay;
    if (t.active) {
      final determinate = t.state == TaskState.downloading;
      overlay = Container(
        color: Colors.black54,
        child: Center(
          child: SizedBox(
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
          ),
        ),
      );
    }
    return Thumb(
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
        return Text('Waiting to start…', style: tt);
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
            ]),
            Text(
              '${fmtBytes(t.received)} / ${fmtBytes(t.total)} · '
              'ETA ${eta == null ? '--' : fmtDuration(eta)}',
              style: tt,
            ),
          ]);
        }
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
            Text('Merging video + audio…', style: tt),
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
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        openFolderWithFeedback(context, File(p).parent.path),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open folder'),
                  ),
                  const Spacer(),
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
                  onPressed: () {
                    t.cancelRequested = true;
                    t.touch();
                  },
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