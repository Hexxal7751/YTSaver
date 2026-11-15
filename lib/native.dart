import 'package:flutter/services.dart';

/// Small bridge to Android helpers implemented in MainActivity.kt.
class Native {
  static const _ch = MethodChannel('ytsaver/native');

  /// Opens a file in an app that can play/view it.
  static Future<bool> openFile(String path) async {
    try {
      return (await _ch.invokeMethod<bool>('openFile', {'path': path})) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the Android share sheet for a file.
  static Future<bool> shareFile(String path, {String title = 'Share'}) async {
    try {
      return (await _ch.invokeMethod<bool>(
              'shareFile', {'path': path, 'title': title})) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 'wifi', 'ethernet', 'cellular', 'none', 'other' or 'unknown'.
  static Future<String> netType() async {
    try {
      return (await _ch.invokeMethod<String>('netType')) ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }
}