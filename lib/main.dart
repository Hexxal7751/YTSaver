import 'package:flutter/material.dart';

import 'ui/downloads_tab.dart';
import 'ui/get_tab.dart';

void main() => runApp(const YtSaverApp());

class YtSaverApp extends StatelessWidget {
  const YtSaverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YTSaver',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.red,
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
    return Scaffold(
      appBar: AppBar(title: const Text('YTSaver')),
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
    );
  }
}
