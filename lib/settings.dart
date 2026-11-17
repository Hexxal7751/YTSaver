import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum QualityPreset { best, p1080, p720, smallest, audio }

class AppSettings extends ChangeNotifier {
  // appearance
  ThemeMode themeMode = ThemeMode.system;
  bool amoled = false;
  int accent = 0xFF7B2FF7;

  // behaviour
  QualityPreset defaultPreset = QualityPreset.best;
  bool watchClipboard = true;
  bool haptics = true;

  // network & queue
  bool wifiOnly = false;
  int warnMobileMb = 200; // 0 = never warn
  int maxConcurrent = 2; // downloads running at the same time (1-4)

  // files
  String filenameTemplate = '{title} [{quality}]';
  String videoBase = 'Movies'; // Movies | Download | DCIM
  String audioBase = 'Music'; // Music | Download | Podcasts
  String subfolder = 'YTSaver';

  static const _root = '/storage/emulated/0';

  String get _sub {
    final s = subfolder.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    return s.isEmpty ? 'YTSaver' : s;
  }

  String get videoPath => '$_root/$videoBase/$_sub';
  String get audioPath => '$_root/$audioBase/$_sub';

  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.byName((m['theme'] as String?) ?? 'system');
      amoled = (m['amoled'] as bool?) ?? false;
      accent = (m['accent'] as int?) ?? 0xFF7B2FF7;
      defaultPreset =
          QualityPreset.values.byName((m['preset'] as String?) ?? 'best');
      watchClipboard = (m['clipboard'] as bool?) ?? true;
      haptics = (m['haptics'] as bool?) ?? true;
      wifiOnly = (m['wifiOnly'] as bool?) ?? false;
      warnMobileMb = (m['warnMb'] as int?) ?? 200;
      maxConcurrent = ((m['maxConcurrent'] as int?) ?? 2).clamp(1, 4);
      filenameTemplate =
          (m['template'] as String?) ?? '{title} [{quality}]';
      videoBase = (m['videoBase'] as String?) ?? 'Movies';
      audioBase = (m['audioBase'] as String?) ?? 'Music';
      subfolder = (m['subfolder'] as String?) ?? 'YTSaver';
      notifyListeners();
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'theme': themeMode.name,
        'amoled': amoled,
        'accent': accent,
        'preset': defaultPreset.name,
        'clipboard': watchClipboard,
        'haptics': haptics,
        'wifiOnly': wifiOnly,
        'warnMb': warnMobileMb,
        'maxConcurrent': maxConcurrent,
        'template': filenameTemplate,
        'videoBase': videoBase,
        'audioBase': audioBase,
        'subfolder': subfolder,
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