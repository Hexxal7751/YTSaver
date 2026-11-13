import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum QualityPreset { best, p1080, p720, smallest, audio }

class AppSettings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  QualityPreset defaultPreset = QualityPreset.best;
  bool watchClipboard = true;
  bool haptics = true;

  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      themeMode =
          ThemeMode.values.byName((m['theme'] as String?) ?? 'system');
      defaultPreset =
          QualityPreset.values.byName((m['preset'] as String?) ?? 'best');
      watchClipboard = (m['clipboard'] as bool?) ?? true;
      haptics = (m['haptics'] as bool?) ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'theme': themeMode.name,
        'preset': defaultPreset.name,
        'clipboard': watchClipboard,
        'haptics': haptics,
      }));
    } catch (_) {}
  }

  void update(void Function() change) {
    change();
    notifyListeners();
    save();
  }
}

final settings = AppSettings();