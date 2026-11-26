import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../screens/chapters_screen.dart';
import '../state/downloads.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../utils/dates.dart';
import 'common.dart';
import 'entry_sheet.dart';

String chapterLabel(Entry e) {
  final total = e.knownChapters;
  if (e.status == EntryStatus.toRead && e.chapter == 0) {
    return total != null ? '$total chapters' : 'Not started';
  }
  return total != null ? 'Ch ${e.chapter} / $total' : 'Ch ${e.chapter}';
}

/// List row: cover, title, status, progress, and a big Resume button that
/// opens the reader where you stopped. Swipe left → delete, after a
/// confirmation (with Undo).
class EntryTile extends ConsumerWidget {
  const EntryTile({super.key, required this.entry, this.dragHandle});

  final Entry entry;
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final statusColor = context.statusColors.of(entry.status);

    return Dismissible(
      key: ValueKey('dismiss-${entry.id}'),
      direction: DismissDirection.endToStart, // swipe left only
      background: _SwipeBg(
        color: c.error,
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        alignLeft: false,
      ),
      confirmDismiss: (_) async {
        final ok = await confirm(context,
            title: 'Delete “${entry.title}”?',
            message: 'It will be removed from your list. You can undo right after.',
            action: 'Delete',
            destructive: true);
        return ok == true; // cancelled → the row slides back
      },
      onDismissed: (_) => deleteWithUndo(context, ref, entry),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showEntrySheet(context, entry.id),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                CoverImage(
                  url: entry.coverUrl,
                  title: entry.title,
                  width: 58,
                  height: 82,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleSmall?.copyWith(height: 1.2),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (entry.hasNewChapters)
                            NewChaptersBadge(entry.unreadChapters),
                          StatusBadge(entry.status, dense: true),
                          TagChip(entry.type.label),
                          if (entry.reread > 0)
                            TagChip('×${entry.reread}',
                                icon: Icons.replay_rounded),
                          if (ref.watch(downloadsProvider.select((s) =>
                              s.done.values.any((d) => d.entryId == entry.id))))
                            Tooltip(
                              message: 'Has downloaded chapters',
                              child: Icon(Icons.download_done_rounded,
                                  size: 16, color: c.onSurfaceVariant),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            chapterLabel(entry),
                            style: context.text.labelMedium?.copyWith(
                              color: c.onSurface,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                          if (entry.lastReadAt != null) ...[
                            Text('  ·  ',
                                style: context.text.labelSmall
                                    ?.copyWith(color: c.onSurfaceVariant)),
                            Flexible(
                              child: Text(
                                relativeTime(entry.lastReadAt!),
                                overflow: TextOverflow.ellipsis,
                                style: context.text.labelSmall
                                    ?.copyWith(color: c.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (entry.progress != null) ...[
                        const SizedBox(height: 6),
                        ThinProgress(value: entry.progress, color: statusColor),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                dragHandle ?? ResumeButton(entry: entry),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the reader at your last chapter and page — or the next unread
/// chapter (the first one, if you haven't started). The first time, it asks
/// which source to read from.
class ResumeButton extends ConsumerWidget {
  const ResumeButton({super.key, required this.entry, this.compact = false});
  final Entry entry;

  /// Smaller round version for grid cards.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final link = ref.watch(readingLinksProvider.select((m) => m[entry.id]));
    final started = (link?.hasProgress ?? false) || entry.chapter > 0;
    Future<void> go() async {
      try {
        await resumeReading(context, ref, entry);
      } catch (e) {
        if (context.mounted) showSnack(context, friendlyError(e), error: true);
      }
    }

    // Bookmark only (no chapter list): cards don't fetch every title's
    // chapters just for a tooltip.
    final label = readButtonLabel(entry, link, const []);
    if (compact) {
      return Tooltip(
        message: label,
        child: Material(
          color: c.primary,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: go,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.play_arrow_rounded, color: c.onPrimary, size: 22),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: label,
      child: Material(
        color: c.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: go,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(
              started ? Icons.play_arrow_rounded : Icons.menu_book_rounded,
              color: c.primary,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignLeft,
  });

  final Color color;
  final IconData icon;
  final String label;
  final bool alignLeft;

  @override
  Widget build(BuildContext context) {
    final children = [
      Icon(icon, color: color),
      const SizedBox(width: 8),
      Text(label,
          style: context.text.labelLarge?.copyWith(color: color)),
    ];
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: alignLeft ? children : children.reversed.toList(),
      ),
    );
  }
}

/// Grid card: big cover with title and progress over a gradient.
class EntryGridCard extends ConsumerWidget {
  const EntryGridCard({super.key, required this.entry});
  final Entry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusColor = context.statusColors.of(entry.status);
    return GestureDetector(
      onTap: () => showEntrySheet(context, entry.id),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(url: entry.coverUrl, title: entry.title, radius: 0),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.45, 1],
                  colors: [Colors.transparent, Color(0xE6000000)],
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
            if (entry.hasNewChapters)
              Positioned(
                top: 8,
                right: 8,
                child: NewChaptersBadge(entry.unreadChapters),
              ),
            Positioned(
              right: 8,
              bottom: 52,
              child: ResumeButton(entry: entry, compact: true),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelLarge
                        ?.copyWith(color: Colors.white, height: 1.15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    chapterLabel(entry),
                    style: context.text.labelSmall
                        ?.copyWith(color: Colors.white70),
                  ),
                  if (entry.progress != null) ...[
                    const SizedBox(height: 6),
                    ThinProgress(value: entry.progress, color: statusColor),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "+3 new" pill for series with chapters out that you haven't read.
class NewChaptersBadge extends StatelessWidget {
  const NewChaptersBadge(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: '$count new chapter${count == 1 ? '' : 's'} out',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.tertiary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fiber_new_rounded, size: 14, color: c.onTertiary),
            const SizedBox(width: 3),
            Text(
              count > 99 ? '99+' : '+$count',
              style: context.text.labelSmall?.copyWith(
                color: c.onTertiary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Deletes an entry and shows an "Undo" snackbar.
Future<void> deleteWithUndo(
    BuildContext context, WidgetRef ref, Entry entry) async {
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(entriesProvider.notifier);
  try {
    await notifier.remove(entry);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text('Removed “${entry.title}”'),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            await notifier.restore(entry);
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
          }
        },
      ),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}
