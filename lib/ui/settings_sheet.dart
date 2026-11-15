import 'package:flutter/material.dart';

import '../filenames.dart';
import '../open_helper.dart';
import '../presets.dart';
import '../settings.dart';
import 'storage_page.dart';

void showSettingsSheet(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
  );
}

const _accents = <int>[
  0xFF7B2FF7, // violet
  0xFF3B5BFF, // blue
  0xFFE02BD3, // magenta
  0xFF00A99D, // teal
  0xFF2E9E5B, // green
  0xFFF28C28, // orange
  0xFFE5384F, // red
  0xFF8D6E63, // brown
];

const _warnChoices = <int, String>{
  0: 'Never',
  50: '50 MB',
  200: '200 MB',
  500: '500 MB',
  1024: '1 GB',
};

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _tpl =
      TextEditingController(text: settings.filenameTemplate);
  late final TextEditingController _sub =
      TextEditingController(text: settings.subfolder);

  @override
  void dispose() {
    _tpl.dispose();
    _sub.dispose();
    super.dispose();
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(t,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  String get _preview => renderName(
        settings.filenameTemplate,
        title: 'My Video',
        quality: '1080p + 128kbps',
        channel: 'My Channel',
        id: 'abc123def45',
      );

  void _insertTag(String tag) {
    final sel = _tpl.selection;
    final text = _tpl.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, tag);
    _tpl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + tag.length),
    );
    settings.update(() => settings.filenameTemplate = next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final small = Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              // ---------- appearance ----------
              _h('Appearance'),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('AMOLED black'),
                subtitle: const Text('Pure black background in dark mode'),
                value: settings.amoled,
                onChanged: (v) => settings.update(() => settings.amoled = v),
              ),
              const SizedBox(height: 4),
              Text('Accent color', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 12, children: [
                for (final c in _accents)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => settings.update(() => settings.accent = c),
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: Color(c),
                      child: settings.accent == c
                          ? const Icon(Icons.check, color: Colors.white, size: 20)
                          : null,
                    ),
                  ),
              ]),

              // ---------- downloads ----------
              _h('Downloads'),
              Text('Default quick download',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final p in QualityPreset.values)
                  ChoiceChip(
                    label: Text(p.title),
                    selected: settings.defaultPreset == p,
                    onSelected: (_) =>
                        settings.update(() => settings.defaultPreset = p),
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wi-Fi only'),
                subtitle: const Text(
                    'Downloads wait until you are on Wi-Fi (you can override per download)'),
                value: settings.wifiOnly,
                onChanged: (v) => settings.update(() => settings.wifiOnly = v),
              ),
              if (!settings.wifiOnly) ...[
                const SizedBox(height: 4),
                Text('Warn before downloads on mobile data larger than',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final e in _warnChoices.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: settings.warnMobileMb == e.key,
                      onSelected: (_) =>
                          settings.update(() => settings.warnMobileMb = e.key),
                    ),
                ]),
              ],
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

              // ---------- file names ----------
              _h('File names'),
              TextField(
                controller: _tpl,
                decoration: const InputDecoration(
                  labelText: 'Filename template',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    settings.update(() => settings.filenameTemplate = v),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final tag in kTemplateTags)
                  ActionChip(label: Text(tag), onPressed: () => _insertTag(tag)),
                ActionChip(
                  avatar: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Reset'),
                  onPressed: () {
                    _tpl.text = kDefaultTemplate;
                    settings.update(
                        () => settings.filenameTemplate = kDefaultTemplate);
                  },
                ),
              ]),
              const SizedBox(height: 8),
              Text('Example: $_preview.mp4', style: small),

              // ---------- save locations ----------
              _h('Save locations'),
              Text('Videos', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final b in const ['Movies', 'Download', 'DCIM'])
                  ChoiceChip(
                    label: Text(b),
                    selected: settings.videoBase == b,
                    onSelected: (_) =>
                        settings.update(() => settings.videoBase = b),
                  ),
              ]),
              const SizedBox(height: 14),
              Text('Audio', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final b in const ['Music', 'Download', 'Podcasts'])
                  ChoiceChip(
                    label: Text(b),
                    selected: settings.audioBase == b,
                    onSelected: (_) =>
                        settings.update(() => settings.audioBase = b),
                  ),
              ]),
              const SizedBox(height: 14),
              TextField(
                controller: _sub,
                decoration: const InputDecoration(
                  labelText: 'Subfolder name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => settings.update(() => settings.subfolder = v),
              ),
              const SizedBox(height: 8),
              Text('Videos: ${settings.videoPath}\nAudio: ${settings.audioPath}',
                  style: small),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton.icon(
                  onPressed: () => openFolderWithFeedback(context, videoDir),
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('Open videos'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openFolderWithFeedback(context, audioDir),
                  icon: const Icon(Icons.music_note_outlined),
                  label: const Text('Open audio'),
                ),
              ]),

              // ---------- storage ----------
              _h('Storage'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Storage overview and clean-up'),
                subtitle: const Text('See what YTSaver uses and free up space'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const StoragePage()),
                ),
              ),
              const SizedBox(height: 16),
              Text('Only download content you have the right to save.',
                  style: small),
            ],
          );
        },
      ),
    );
  }
}