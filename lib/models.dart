import 'package:flutter/foundation.dart';

enum TaskState { queued, downloading, merging, done, failed, cancelled }

class DownloadTask extends ChangeNotifier {
  DownloadTask({required this.title, required this.label});

  final String title;
  final String label;
  TaskState state = TaskState.queued;
  double progress = 0;
  int received = 0;
  int total = 0;
  double speed = 0; // bytes per second
  String? outputPath;
  String? error;
  bool cancelRequested = false;
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
}

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
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0
      ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
      : '${d.inMinutes}:${two(d.inSeconds % 60)}';
}
