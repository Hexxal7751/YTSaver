import 'package:flutter/material.dart';

import '../download_manager.dart';
import '../models.dart';

class DownloadsTab extends StatelessWidget {
  const DownloadsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        if (manager.tasks.isEmpty) {
          return const Center(child: Text('No downloads yet'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: manager.tasks.length,
          itemBuilder: (_, i) => _TaskCard(task: manager.tasks[i]),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});
  final DownloadTask task;

  String _status(DownloadTask t) {
    switch (t.state) {
      case TaskState.queued:
        return 'Queued';
      case TaskState.downloading:
        final eta = t.eta;
        return '${fmtBytes(t.received)} / ${fmtBytes(t.total)} · '
            '${fmtBytes(t.speed)}/s · ETA ${eta == null ? '--' : fmtDuration(eta)}';
      case TaskState.merging:
        return 'Merging video + audio…';
      case TaskState.done:
        return 'Saved to ${t.outputPath}';
      case TaskState.failed:
        return 'Failed: ${t.error}';
      case TaskState.cancelled:
        return 'Cancelled';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(task.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (task.active)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      task.cancelRequested = true;
                      task.touch();
                    },
                  ),
              ]),
              Text(task.label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (task.active)
                LinearProgressIndicator(
                  value: (task.state == TaskState.queued ||
                          task.state == TaskState.merging)
                      ? null
                      : task.progress,
                ),
              const SizedBox(height: 6),
              Row(children: [
                if (task.state == TaskState.merging)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (task.state == TaskState.done)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.check_circle, size: 16, color: Colors.green),
                  ),
                Expanded(
                  child: Text(_status(task),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ]),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Verbose log (${task.logs.length})',
                    style: Theme.of(context).textTheme.bodySmall),
                children: [
                  Container(
                    height: 160,
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Colors.black,
                    child: SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        task.logs.join('\n'),
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.greenAccent),
                      ),
                    ),
                  ),
                ],
              ),
            ]),
          ),
        );
      },
    );
  }
}