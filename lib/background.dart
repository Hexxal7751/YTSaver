import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The foreground service only keeps the app process alive (and shows the
/// ongoing notification); the real work happens in download_manager.dart.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class Bg {
  static final _notif = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _nextId = 100;

  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ytsaver_progress',
        channelName: 'Download progress',
        channelDescription: 'Shown while downloads are running.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await _notif.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await FlutterForegroundTask.requestNotificationPermission();
    _ready = true;
  }

  static Future<void> start() async {
    try {
      if (!_ready) await init();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 7001,
        notificationTitle: 'YTSaver',
        notificationText: 'Starting download…',
        callback: startCallback,
      );
    } catch (_) {
      // Downloads still run (foreground only) if the service can't start.
    }
  }

  static Future<void> update(String title, String text) async {
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  /// Normal (non-ongoing) push notification for finished/failed downloads.
  static Future<void> notify(String title, String body) async {
    try {
      await _notif.show(
        _nextId++,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ytsaver_done',
            'Download results',
            channelDescription: 'Tells you when a download finishes.',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (_) {}
  }
}