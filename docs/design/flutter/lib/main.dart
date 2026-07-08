import 'package:flutter/material.dart';

import 'core/theme/watchnook_theme.dart';
import 'features/detail/title_detail_screen.dart';
import 'features/import/import_screen.dart';
import 'features/library/library_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stats/stats_screen.dart';
import 'features/up_next/up_next_screen.dart';

void main() => runApp(const WatchnookApp());

class WatchnookApp extends StatelessWidget {
  const WatchnookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watchnook',
      debugShowCheckedModeBanner: false,
      theme: WatchnookTheme.light,
      darkTheme: WatchnookTheme.dark,
      // Dark-leaning by default (wire dynamic_color for Material You).
      themeMode: ThemeMode.dark,
      routes: {
        '/settings': (_) => const SettingsScreen(),
        '/import': (_) => const ImportScreen(),
        '/detail': (_) => const TitleDetailScreen(),
      },
      home: const HomeShell(),
    );
  }
}

/// Bottom-nav shell. Settings lives in each screen's app bar (option C1).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _screens = [
    LibraryScreen(),
    UpNextScreen(),
    SearchScreen(),
    StatsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: 'Up next',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Stats',
          ),
        ],
      ),
    );
  }
}
