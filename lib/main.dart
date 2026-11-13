import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background.dart';
import 'open_helper.dart';
import 'ui/downloads_tab.dart';
import 'ui/get_tab.dart';

const _seed = Color(0xFF6B2FF5);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Bg.init();
  runApp(const YtSaverApp());
}

class YtSaverApp extends StatelessWidget {
  const YtSaverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YTSaver',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
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
          title: Row(children: [
            Image.asset('assets/logo.png', height: 32),
            const SizedBox(width: 10),
            const Text('YTSaver'),
          ]),
          actions: [
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Open save folder',
              onPressed: () => openFolderWithFeedback(context, videoDir),
            ),
          ],
        ),
        body: IndexedStack(index: _tab, children: [
          GetTab(onQueued: () => setState(() => _tab = 1)),
          const DownloadsTab(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.search), label: 'Get'),
            NavigationDestination(icon: Icon(Icons.download), label: 'Downloads'),
          ],
        ),
      ),
    );
  }
}