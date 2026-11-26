import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'discover_screen.dart';
import 'list_screen.dart';
import 'profile_screen.dart';
import 'stats_screen.dart';
import 'updates_screen.dart';
import '../models/entry.dart';
import '../services/background.dart';
import '../services/inbox.dart';
import '../state/inbox.dart';
import '../state/providers.dart';
import '../widgets/update_dialog.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _updatesTab = 4;
  final _openedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    Notifications.tapped.addListener(_onNotificationTap);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Opened by tapping a notification while the app was closed?
      final launch = await Notifications.launchPayload();
      if (launch != null) {
        _openFromNotification(launch);
      } else {
        _onNotificationTap();
      }
      // Quietly look for a new GitHub release (at most every 12 hours).
      if (mounted) checkForUpdates(context, ref);
    });
  }

  @override
  void dispose() {
    Notifications.tapped.removeListener(_onNotificationTap);
    super.dispose();
  }

  void _onNotificationTap() {
    final payload = Notifications.tapped.value;
    if (payload == null) return;
    Notifications.tapped.value = null;
    _openFromNotification(payload);
  }

  /// Goes to the Updates tab and, for a single series, opens it.
  void _openFromNotification(String payload) {
    if (!mounted) return;
    // Close any sheet or page on top so the series opens on the tab.
    Navigator.of(context).popUntil((r) => r.isFirst);
    _select(_updatesTab);
    ref.read(inboxProvider.notifier).reload();
    if (payload != Notifications.updatesPayload) {
      openSeries(context, ref, payload);
    }
  }

  static const _pages = <Widget>[
    ListScreen(tab: ListTab.library),
    ListScreen(tab: ListTab.toRead),
    DiscoverScreen(),
    StatsScreen(),
    UpdatesScreen(),
    ProfileScreen(),
  ];

  void _select(int i) {
    if (i == 3 && _index != 3) {
      // Re-pull chart data whenever Stats is opened.
      ref.invalidate(chaptersPerDayProvider);
      ref.invalidate(completionsPerMonthProvider);
    }
    if (i == _updatesTab && _index != _updatesTab) {
      // The background job may have added alerts.
      ref.read(inboxProvider.notifier).reload();
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final toReadCount = ref.watch(
        statusCountsProvider.select((m) => m[EntryStatus.toRead] ?? 0));
    final unread = ref.watch(unreadAlertsProvider);
    // New chapters found while you're in the app: say so here too.
    ref.listen<List<ChapterAlert>>(inboxProvider, (before, now) {
      String key(ChapterAlert a) => '${a.entryId}@${a.at.millisecondsSinceEpoch}';
      final old = {for (final a in before ?? const <ChapterAlert>[]) key(a)};
      final added = now
          .where((a) =>
              !a.read && a.at.isAfter(_openedAt) && !old.contains(key(a)))
          .length;
      if (added <= 0 || _index == _updatesTab) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added == 1
            ? 'A series you read has a new chapter'
            : '$added series you read have new chapters'),
        action: SnackBarAction(
            label: 'View', onPressed: () => _select(_updatesTab)),
      ));
    });

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
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_none_rounded),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_rounded),
            ),
            label: 'Updates',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
