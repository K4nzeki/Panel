import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'discover_screen.dart';
import 'list_screen.dart';
import 'profile_screen.dart';
import 'stats_screen.dart';
import '../models/entry.dart';
import '../state/providers.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _pages = <Widget>[
    ListScreen(tab: ListTab.library),
    ListScreen(tab: ListTab.toRead),
    DiscoverScreen(),
    StatsScreen(),
    ProfileScreen(),
  ];

  void _select(int i) {
    if (i == 3 && _index != 3) {
      // Re-pull chart data whenever Stats is opened.
      ref.invalidate(chaptersPerDayProvider);
      ref.invalidate(completionsPerMonthProvider);
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final toReadCount = ref.watch(
        statusCountsProvider.select((m) => m[EntryStatus.toRead] ?? 0));

    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark_rounded),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: toReadCount > 0,
              label: Text('$toReadCount'),
              child: const Icon(Icons.bookmark_border_rounded),
            ),
            selectedIcon: Badge(
              isLabelVisible: toReadCount > 0,
              label: Text('$toReadCount'),
              child: const Icon(Icons.bookmark_rounded),
            ),
            label: 'To Read',
          ),
          const NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore_rounded),
            label: 'Discover',
          ),
          const NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Stats',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
