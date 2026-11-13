import 'package:flutter/material.dart';

import '../open_helper.dart';
import '../presets.dart';
import '../settings.dart';

void showSettingsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SettingsBody(),
  );
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(t,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Settings',
                  style: Theme.of(context).textTheme.headlineSmall),
              _label(context, 'Theme'),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('Auto'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode)),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode)),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) =>
                    settings.update(() => settings.themeMode = s.first),
              ),
              _label(context, 'Default quick download'),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final p in QualityPreset.values)
                  ChoiceChip(
                    label: Text(p.title),
                    selected: settings.defaultPreset == p,
                    onSelected: (_) =>
                        settings.update(() => settings.defaultPreset = p),
                  ),
              ]),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Detect links in clipboard'),
                subtitle: const Text('Offer to fetch a copied YouTube link'),
                value: settings.watchClipboard,
                onChanged: (v) =>
                    settings.update(() => settings.watchClipboard = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Haptic feedback'),
                subtitle: const Text('Small vibrations on start and finish'),
                value: settings.haptics,
                onChanged: (v) => settings.update(() => settings.haptics = v),
              ),
              _label(context, 'Save locations'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.movie_outlined),
                title: const Text('Videos'),
                subtitle: const Text('Movies/YTSaver'),
                trailing: TextButton(
                  onPressed: () => openFolderWithFeedback(context, videoDir),
                  child: const Text('Open'),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.music_note_outlined),
                title: const Text('Audio'),
                subtitle: const Text('Music/YTSaver'),
                trailing: TextButton(
                  onPressed: () => openFolderWithFeedback(context, audioDir),
                  child: const Text('Open'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Only download content you have the right to save.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        );
      },
    );
  }
}