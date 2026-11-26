import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../services/inbox.dart';
import '../state/inbox.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/dates.dart';
import '../widgets/common.dart';
import '../widgets/entry_sheet.dart';

/// Opens the series an alert (or a tapped notification) is about.
Future<void> openSeries(
    BuildContext context, WidgetRef ref, String entryId) async {
  await ref.read(inboxProvider.notifier).markRead(entryId);
  List<Entry> list;
  try {
    list = await ref.read(entriesProvider.future);
  } catch (_) {
    list = ref.read(entriesProvider).value ?? const [];
  }
  if (!context.mounted) return;
  if (!list.any((e) => e.id == entryId)) {
    showSnack(context, 'This series is no longer in your list.');
    return;
  }
  await showEntrySheet(context, entryId);
}

/// "Updates" tab: every new-chapter notification, so you can jump straight
/// to the series.
class UpdatesScreen extends ConsumerWidget {
  const UpdatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(inboxProvider);
    final unread = ref.watch(unreadAlertsProvider);
    final checking = ref.watch(updateCheckingProvider);
    final entries = {
      for (final e in ref.watch(entriesProvider).value ?? const <Entry>[])
        e.id: e,
    };
    final c = context.colors;
    final inbox = ref.read(inboxProvider.notifier);

    Future<void> refresh() async {
      await ref.read(entriesProvider.notifier).checkUpdates(force: true);
      await inbox.reload();
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              toolbarHeight: 84,
              titleSpacing: 20,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    checking
                        ? 'Checking for new chapters…'
                        : unread > 0
                            ? '$unread new'
                            : 'New chapters',
                    style: context.text.labelLarge
                        ?.copyWith(color: c.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text('Updates', style: context.text.headlineSmall),
                ],
              ),
              actions: [
                if (unread > 0)
                  IconButton(
                    tooltip: 'Mark all as read',
                    onPressed: inbox.markAllRead,
                    icon: const Icon(Icons.done_all_rounded),
                  ),
                if (alerts.isNotEmpty)
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v != 'clear') return;
                      final ok = await confirm(context,
                          title: 'Clear all updates?', action: 'Clear');
                      if (ok == true) await inbox.clear();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'clear', child: Text('Clear all')),
                    ],
                  ),
                const SizedBox(width: 8),
              ],
            ),
            if (alerts.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: 'No new chapters yet',
                  message: 'When a series you are reading gets a new chapter, '
                      "it shows up here. Pull down to check now.",
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList.builder(
                  itemCount: alerts.length,
                  itemBuilder: (context, i) {
                    final a = alerts[i];
                    return _AlertTile(
                      key: ValueKey(a.entryId),
                      alert: a,
                      entry: entries[a.entryId],
                      onTap: () => openSeries(context, ref, a.entryId),
                      onDismissed: () async {
                        await inbox.remove(a.entryId);
                        if (context.mounted) {
                          showSnack(context, 'Removed',
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () => inbox.restore(a, i),
                              ));
                        }
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({
    super.key,
    required this.alert,
    required this.entry,
    required this.onTap,
    required this.onDismissed,
  });

  final ChapterAlert alert;
  final Entry? entry;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = entry;
    // Prefer what's in the list now (a cover may have been found since).
    final cover = (e?.coverUrl?.isNotEmpty ?? false) ? e!.coverUrl : alert.coverUrl;
    final waiting = e == null ? alert.unread : e.unreadChapters;
    final caughtUp = e != null && waiting == 0;
    final n = alert.unread;

    return Dismissible(
      key: ValueKey('dismiss-${alert.entryId}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: c.errorContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(Icons.delete_outline_rounded, color: c.onErrorContainer),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: alert.read ? c.surfaceContainerLow : c.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                CoverImage(
                    url: cover, title: alert.title, width: 52, height: 72),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e?.title ?? alert.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleMedium?.copyWith(
                          fontWeight:
                              alert.read ? FontWeight.w500 : FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Chapter ${alert.latest} is out · '
                        '$n new chapter${n == 1 ? '' : 's'}',
                        style: context.text.bodySmall
                            ?.copyWith(color: c.onSurfaceVariant),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        caughtUp
                            ? '${relativeTime(alert.at)} · caught up'
                            : relativeTime(alert.at),
                        style: context.text.labelSmall
                            ?.copyWith(color: c.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (!alert.read)
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(left: 8, right: 4),
                    decoration:
                        BoxDecoration(color: c.primary, shape: BoxShape.circle),
                  )
                else
                  Icon(Icons.chevron_right_rounded, color: c.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
