import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ShareEvent {
  ShareEvent(this.text);
  final String text;
  bool handled = false;
}

/// Latest text shared into the app from another app's Share menu.
final ValueNotifier<ShareEvent?> sharedLink = ValueNotifier<ShareEvent?>(null);

class ShareIntake {
  static const _ch = MethodChannel('ytsaver/share');

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) {
        sharedLink.value = ShareEvent(call.arguments as String);
      }
      return null;
    });
    _ch.invokeMethod<String>('getInitial').then((t) {
      if (t != null && t.isNotEmpty) sharedLink.value = ShareEvent(t);
    }).catchError((_) {});
  }
}