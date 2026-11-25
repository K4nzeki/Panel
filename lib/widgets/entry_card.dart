import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/dates.dart';
import 'common.dart';
import 'entry_sheet.dart';

String chapterLabel(Entry e) {
  final total = e.totalChapters;
  if (e.status == EntryStatus.toRead && e.chapter == 0) {
    return total != null ? '$total chapters' : 'Not started';
  }
  return total != null ? 'Ch ${e.chapter} / $total' : 'Ch ${e.chapter}';
}

/// List row: cover, title, status, progress, and a big "+1" button.
/// Swipe right → +1 chapter. Swipe left → delete (with Undo).
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
      background: _SwipeBg(
        color: c.primary,
        icon: Icons.add_rounded,
        label: '+1 chapter',
        alignLeft: true,
      ),
      secondaryBackground: _SwipeBg(
        color: c.error,
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        alignLeft: false,
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          await _bump(context, ref, 1);
          return false; // keep the row; it just updates
        }
        return true;
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
                          StatusBadge(entry.status, dense: true),
                          TagChip(entry.type.label),
                          if (entry.reread > 0)
                            TagChip('×${entry.reread}',
                                icon: Icons.replay_rounded),
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
                dragHandle ??
                    _PlusOneButton(onTap: () => _bump(context, ref, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _bump(BuildContext context, WidgetRef ref, int by) async {
    try {
      await ref.read(entriesProvider.notifier).bumpChapter(entry, by);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }
}

class _PlusOneButton extends StatelessWidget {
  const _PlusOneButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Read next chapter',
      child: Material(
        color: c.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, color: c.primary, size: 22),
                Text('1',
                    style: context.text.labelSmall?.copyWith(
                        color: c.primary, fontWeight: FontWeight.w800)),
              ],
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
