import 'package:flutter/foundation.dart';

enum TaskState { queued, downloading, merging, done, failed, cancelled }

class DownloadTask extends ChangeNotifier {
  DownloadTask({
    required this.title,
    required this.label,
    this.videoId = '',
    this.thumbnailUrl,
    this.channel,
    this.videoDuration,
    this.audioOnly = false,
    String? id,
    DateTime? createdAt,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String label;
  final String videoId;
  final String? thumbnailUrl;
  final String? channel;
  final Duration? videoDuration;
  final bool audioOnly;
  final DateTime createdAt;

  TaskState state = TaskState.queued;
  double progress = 0;
  int received = 0;
  int total = 0;
  double speed = 0; // bytes per second
  String? outputPath;
  String? error;
  String? note; // extra message when done (e.g. merge fallback)
  int? fileBytes;
  bool cancelRequested = false;
  Object? retryPayload; // the DownloadRequest, used by "Retry"
  final List<String> logs = [];

  Duration? get eta {
    if (speed <= 1 || total == 0) return null;
    return Duration(seconds: ((total - received) / speed).round());
  }

  bool get active =>
      state == TaskState.queued ||
      state == TaskState.downloading ||
      state == TaskState.merging;

  void log(String msg) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    logs.add('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $msg');
    if (logs.length > 400) logs.removeRange(0, logs.length - 400);
    notifyListeners();
  }

  void touch() => notifyListeners();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'label': label,
        'videoId': videoId,
        'thumb': thumbnailUrl,
        'channel': channel,
        'durationMs': videoDuration?.inMilliseconds,
        'audio': audioOnly,
        'created': createdAt.millisecondsSinceEpoch,
        'path': outputPath,
        'note': note,
        'bytes': fileBytes,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final ms = j['durationMs'] as int?;
    final t = DownloadTask(
      id: j['id'] as String?,
      title: (j['title'] as String?) ?? '',
      label: (j['label'] as String?) ?? '',
      videoId: (j['videoId'] as String?) ?? '',
      thumbnailUrl: j['thumb'] as String?,
      channel: j['channel'] as String?,
      videoDuration: ms == null ? null : Duration(milliseconds: ms),
      audioOnly: (j['audio'] as bool?) ?? false,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((j['created'] as int?) ?? 0),
    );
    t.state = TaskState.done;
    t.progress = 1;
    t.outputPath = j['path'] as String?;
    t.note = j['note'] as String?;
    t.fileBytes = j['bytes'] as int?;
    return t;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String fmtBytes(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtDuration(Duration d) {
  final h = d.inHours;
  return h > 0
      ? '$h:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}'
      : '${d.inMinutes}:${_two(d.inSeconds % 60)}';
}

String fmtCount(int n) {
  if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(1)}B';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)}K';
  return '$n';
}

String fmtDate(DateTime d) {
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

String timeAgo(DateTime d) {
  final s = DateTime.now().difference(d);
  if (s.inMinutes < 1) return 'just now';
  if (s.inMinutes < 60) return '${s.inMinutes} min ago';
  if (s.inHours < 24) return '${s.inHours} h ago';
  if (s.inDays < 30) return '${s.inDays} d ago';
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}