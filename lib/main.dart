import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background.dart';
import 'download_manager.dart';
import 'open_helper.dart';
import 'settings.dart';
import 'theme.dart';
import 'ui/downloads_tab.dart';
import 'ui/get_tab.dart';
import 'ui/settings_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const YtSaverApp());
  // Start these AFTER the UI is up; none of them throw.
  settings.load();
  manager.loadHistory();
  Bg.init();
}

class YtSaverApp extends StatelessWidget {
  const YtSaverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'YTSaver',
        debugShowCheckedModeBanner: false,
        themeMode: settings.themeMode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(children: [
            Image.asset('assets/logo.png', height: 34),
            const SizedBox(width: 10),
            ShaderMask(
              shaderCallback: (r) => brandGradient.createShader(r),
              child: const Text('YTSaver',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 22)),
            ),
          ]),
          actions: [
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Open save folder',
              onPressed: () => openFolderWithFeedback(context, videoDir),
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Settings',
              onPressed: () => showSettingsSheet(context),
            ),
          ],
        ),
        body: Column(children: [
          ValueListenableBuilder<String?>(
            valueListenable: Bg.initError,
            builder: (context, err, _) {
              if (err == null) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.all(8),
                child: Text('Background/notification setup failed: $err',
                    style: const TextStyle(fontSize: 12)),
              );
            },
          ),
          Expanded(
            child: IndexedStack(index: _tab, children: [
              GetTab(onQueued: () => setState(() => _tab = 1)),
              const DownloadsTab(),
            ]),
          ),
        ]),
        bottomNavigationBar: ListenableBuilder(
          listenable: manager,
          builder: (context, _) {
            final n = manager.tasks.where((t) => t.active).length;
            return NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.bolt_outlined),
                  selectedIcon: Icon(Icons.bolt),
                  label: 'Get',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: n > 0,
                    label: Text('$n'),
                    child: const Icon(Icons.download_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: n > 0,
                    label: Text('$n'),
                    child: const Icon(Icons.download),
                  ),
                  label: 'Downloads',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}