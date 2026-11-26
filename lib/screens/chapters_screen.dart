import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/downloads.dart';
import '../services/mangadex.dart';
import '../services/sources/mangadex_source.dart';
import '../state/downloads.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../utils/dates.dart';
import '../widgets/common.dart';
import '../widgets/entry_sheet.dart' show confirm;
import 'reader_screen.dart';
import 'source_picker_screen.dart';

// ---------------------------------------------------------------------------
// Entry points used by cards, sheets and lists
// ---------------------------------------------------------------------------

/// The Resume button: opens the reader where you stopped. Picks a source
/// first if the title doesn't have one yet. Works offline from the saved
/// chapter list and downloaded chapters.
Future<void> resumeReading(BuildContext context, WidgetRef ref, Entry entry) async {
  if (ref.read(readingLinksProvider)[entry.id] == null) {
    final picked = await pickReadingSource(context, ref, entry);
    if (!picked || !context.mounted) return;
  }
  final list = await _withSpinner(
      context, ref.read(chaptersProvider(entry.id).notifier).ready());
  if (!context.mounted) return;
  final link = ref.read(readingLinksProvider)[entry.id];
  final current = (ref.read(entriesProvider).value ?? const <Entry>[])
          .where((e) => e.id == entry.id)
          .firstOrNull ??
      entry;
  final target = link == null ? null : resolveResume(current, link, list.chapters);
  if (target == null) {
    // Nothing to open (offline with no saved list, or a filter hides all):
    // the chapter screen explains why.
    await openChapters(context, entry.id);
    return;
  }
  if (target.caughtUp) {
    showSnack(context, "You're caught up — opening the latest chapter.");
  }
  await openReader(context, entry.id, target.order, target.index,
      page: target.page, offset: target.offset);
}

Future<void> openChapters(BuildContext context, String entryId) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChaptersScreen(entryId: entryId)));

/// Opens the reader at [order][index], on [page] and [offset] (0..1 down
/// that page) — the exact spot you stopped at when resuming.
Future<void> openReader(BuildContext context, String entryId,
        List<ChapterInfo> order, int index,
        {int page = 0, double offset = 0}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
          entryId: entryId,
          order: order,
          index: index,
          startPage: page,
          startOffset: offset),
    ));

/// Lets you choose where [entry] is read from. Returns true if one was
/// picked.
Future<bool> pickReadingSource(
    BuildContext context, WidgetRef ref, Entry entry) async {
  final picked = await Navigator.of(context).push<PickedSource>(
      MaterialPageRoute(builder: (_) => SourcePickerScreen(entry: entry)));
  if (picked == null || !context.mounted) return false;
  ref
      .read(readingLinksProvider.notifier)
      .choose(entry.id, picked.source, picked.series);
  // Reading on MangaDex also turns on new-chapter alerts for it.
  if (picked.source.id == MangaDexSource.sourceId && !entry.isLinked) {
    unawaited(ref.read(entriesProvider.notifier).linkSource(
          entry,
          SourceManga(
              id: picked.series.key,
              title: picked.series.title,
              coverUrl: picked.series.coverUrl),
          keepCover: entry.coverUrl != null && entry.coverUrl!.isNotEmpty,
        ).catchError((_) {}));
  }
  return true;
}

/// Shows a spinner if [f] takes more than a moment.
Future<T> _withSpinner<T>(BuildContext context, Future<T> f) async {
  var done = false, shown = false;
  final timer = Timer(const Duration(milliseconds: 350), () {
    if (done || !context.mounted) return;
    shown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      // Back can't close it: this code closes it when the work is done.
      builder: (_) => const PopScope(
          canPop: false, child: Center(child: CircularProgressIndicator())),
    );
  });
  try {
    return await f;
  } finally {
    done = true;
    timer.cancel();
    if (shown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

// ---------------------------------------------------------------------------
// Chapters screen
// ---------------------------------------------------------------------------

/// A title's chapters on its source: pick the source, filter by scanlator,
/// read, and download for offline.
class ChaptersScreen extends ConsumerWidget {
  const ChaptersScreen({super.key, required this.entryId});
  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = (ref.watch(entriesProvider).value ?? const <Entry>[])
        .where((e) => e.id == entryId)
        .firstOrNull;
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Not in your list',
            message: 'This title was removed.'),
      );
    }
    final link = ref.watch(readingLinksProvider.select((m) => m[entryId]));
    if (link == null) {
      return Scaffold(
        appBar: AppBar(title: Text(entry.title)),
        body: EmptyState(
          icon: Icons.travel_explore_rounded,
          title: 'Choose where to read it',
          message: 'Pick MangaDex or one of your extension sites. Panel '
              'remembers your choice and where you stopped.',
          action: FilledButton.icon(
            onPressed: () => pickReadingSource(context, ref, entry),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Choose source'),
          ),
        ),
      );
    }
    return _ChaptersBody(entry: entry, link: link);
  }
}

class _ChaptersBody extends ConsumerWidget {
  const _ChaptersBody({required this.entry, required this.link});
  final Entry entry;
  final ReadingLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final list = ref.watch(chaptersProvider(entry.id));
    final notifier = ref.read(chaptersProvider(entry.id).notifier);
    final downloads = ref.watch(downloadsProvider);

    final counts = <String, int>{};
    for (final ch in list.chapters) {
      counts[ch.scanlatorLabel] = (counts[ch.scanlatorLabel] ?? 0) + 1;
    }
    final groups = counts.keys.toList()..sort();
    // A saved filter for a group that's gone would hide everything.
    final active = link.scanlators.where(counts.containsKey).toSet();
    final shown = filterByScanlator(list.chapters, active);
    final unread = [
      for (final ch in shown)
        if (ch.number == null || ch.number! > entry.chapter) ch,
    ];

    Future<void> download(Iterable<ChapterInfo> chapters) async {
      try {
        final n = ref.read(downloadsProvider.notifier).enqueue(entry, link, chapters);
        if (context.mounted) {
          showSnack(context, n == 0
              ? 'Already downloaded'
              : 'Downloading $n chapter${n == 1 ? '' : 's'}');
        }
      } catch (e) {
        if (context.mounted) showSnack(context, friendlyError(e), error: true);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'unread':
                  await download(unread.reversed);
                case 'all':
                  await download(shown.reversed);
                case 'delete':
                  final ok = await confirm(context,
                      title: 'Delete downloaded chapters?',
                      message: 'They are removed from this phone.',
                      action: 'Delete',
                      destructive: true);
                  if (ok == true) {
                    await ref.read(downloadsProvider.notifier).deleteEntry(entry.id);
                  }
                case 'source':
                  if (context.mounted) await pickReadingSource(context, ref, entry);
                case 'web':
                  final url = link.seriesUrl;
                  if (url != null) {
                    await launchUrl(Uri.parse(url),
                        mode: LaunchMode.externalApplication);
                  }
              }
            },
            itemBuilder: (_) => [
              if (DownloadStore.supported) ...[
                PopupMenuItem(
                    value: 'unread',
                    enabled: unread.isNotEmpty,
                    child: Text('Download unread (${unread.length})')),
                PopupMenuItem(
                    value: 'all',
                    enabled: shown.isNotEmpty,
                    child: Text('Download all (${shown.length})')),
                PopupMenuItem(
                    value: 'delete',
                    enabled: downloads.forEntry(entry.id).isNotEmpty,
                    child: const Text('Delete downloads')),
                const PopupMenuDivider(),
              ],
              const PopupMenuItem(value: 'source', child: Text('Change source')),
              if (link.seriesUrl != null)
                const PopupMenuItem(value: 'web', child: Text('Open in browser')),
            ],
          ),
        ],
      ),
      floatingActionButton: shown.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => resumeReading(context, ref, entry),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(readButtonLabel(entry, link, list.chapters)),
            ),
      body: RefreshIndicator(
        onRefresh: notifier.refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Card(
                  child: ListTile(
                    leading: Icon(Icons.public_rounded, color: c.primary),
                    title: Text(link.sourceName),
                    subtitle: Text(
                      [
                        link.seriesTitle,
                        if (list.fetchedAt != null)
                          'updated ${relativeTime(list.fetchedAt!)}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: () => pickReadingSource(context, ref, entry),
                      child: const Text('Change'),
                    ),
                  ),
                ),
              ),
            ),
            if (list.error != null)
              SliverToBoxAdapter(
                child: _Banner(
                  icon: list.error!.offline
                      ? Icons.cloud_off_rounded
                      : Icons.error_outline_rounded,
                  text: switch (list) {
                    final l when l.downloadedOnly =>
                      "You're offline. Showing your downloaded chapters.",
                    final l when l.error!.offline && l.chapters.isNotEmpty =>
                      "You're offline. Showing the chapter list saved on this phone.",
                    final l => l.error!.message,
                  },
                  action: TextButton(
                      onPressed: notifier.refresh, child: const Text('Retry')),
                ),
              ),
            if (downloads.waitingForConnection)
              SliverToBoxAdapter(
                child: _Banner(
                  icon: Icons.download_rounded,
                  text: 'Downloads are paused until you are back online.',
                  action: TextButton(
                      onPressed: ref.read(downloadsProvider.notifier).resume,
                      child: const Text('Retry')),
                ),
              ),
            if (groups.length > 1)
              SliverToBoxAdapter(
                child: _ScanlatorFilter(
                  entryId: entry.id,
                  groups: groups,
                  counts: counts,
                  active: active,
                ),
              ),
            if (list.loading && list.chapters.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (shown.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.menu_book_outlined,
                  title: 'No chapters',
                  message: list.error != null
                      ? 'Try again when you are online, or choose another source.'
                      : 'This source has no chapters for this title yet.',
                  action: OutlinedButton(
                    onPressed: () => pickReadingSource(context, ref, entry),
                    child: const Text('Choose another source'),
                  ),
                ),
              )
            else ...[
              if (list.loading)
                const SliverToBoxAdapter(
                    child: LinearProgressIndicator(minHeight: 2)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                sliver: SliverList.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _ChapterTile(
                    entry: entry,
                    link: link,
                    chapter: shown[i],
                    shown: shown,
                    showGroup: groups.length > 1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScanlatorFilter extends ConsumerWidget {
  const _ScanlatorFilter({
    required this.entryId,
    required this.groups,
    required this.counts,
    required this.active,
  });

  final String entryId;
  final List<String> groups;
  final Map<String, int> counts;

  /// Empty = all groups.
  final Set<String> active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(readingLinksProvider.notifier);
    bool on(String g) => active.isEmpty || active.contains(g);

    void toggle(String g) {
      final next = active.isEmpty ? groups.toSet() : {...active};
      if (next.contains(g)) {
        if (next.length == 1) return; // keep at least one
        next.remove(g);
      } else {
        next.add(g);
      }
      notifier.setScanlators(
          entryId, next.length == groups.length ? const {} : next);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Scanlators', style: context.text.labelLarge),
            const Spacer(),
            if (active.isNotEmpty)
              TextButton(
                onPressed: () => notifier.setScanlators(entryId, const {}),
                child: const Text('Show all'),
              ),
          ]),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final g in groups)
                GestureDetector(
                  // Long-press: only this group.
                  onLongPress: () => notifier.setScanlators(entryId, {g}),
                  child: FilterChip(
                    label: Text('$g  ${counts[g]}'),
                    selected: on(g),
                    onSelected: (_) => toggle(g),
                  ),
                ),
            ],
          ),
          Text(
            'Tap to hide or show a group, long-press to show only that one. '
            'Resume and "next chapter" follow this filter.',
            style: context.text.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ChapterTile extends ConsumerWidget {
  const _ChapterTile({
    required this.entry,
    required this.link,
    required this.chapter,
    required this.shown,
    required this.showGroup,
  });

  final Entry entry;
  final ReadingLink link;
  final ChapterInfo chapter;
  final List<ChapterInfo> shown;
  final bool showGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final n = chapter.number;
    final read = n != null && n <= entry.chapter;
    final isLast = link.lastChapterKey == chapter.key;
    final dl = ref.watch(downloadsProvider);
    final downloaded = dl.find(entry.id, chapter.key) != null;
    final queued = dl.isQueued(entry.id, chapter.key);
    final active = dl.activeId == downloadId(entry.id, chapter.key);
    final failed = dl.failed[downloadId(entry.id, chapter.key)];

    void open() {
      final order = readingOrder(shown, preferred: chapter.scanlatorLabel);
      var i = order.indexWhere((x) => x.key == chapter.key);
      final o = i < 0 ? [chapter] : order;
      if (i < 0) i = 0;
      final resume = isLast && !link.lastFinished;
      openReader(context, entry.id, o, i,
          page: resume ? link.lastPage : 0,
          offset: resume ? link.lastPageOffset : 0);
    }

    final Widget trailing;
    if (!DownloadStore.supported) {
      trailing = const SizedBox.shrink();
    } else if (downloaded) {
      trailing = IconButton(
        tooltip: 'Downloaded · tap to delete',
        icon: Icon(Icons.download_done_rounded, color: c.primary),
        onPressed: () async {
          final ok = await confirm(context,
              title: 'Delete this download?', action: 'Delete', destructive: true);
          if (ok == true) {
            await ref.read(downloadsProvider.notifier).delete(entry.id, chapter.key);
          }
        },
      );
    } else if (active) {
      final total = dl.activeTotal;
      trailing = IconButton(
        tooltip: 'Cancel download',
        onPressed: () =>
            ref.read(downloadsProvider.notifier).cancel(entry.id, chapter.key),
        icon: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: total > 0 ? dl.activeDone / total : null,
          ),
        ),
      );
    } else if (queued) {
      trailing = IconButton(
        tooltip: 'Queued · tap to cancel',
        onPressed: () =>
            ref.read(downloadsProvider.notifier).cancel(entry.id, chapter.key),
        icon: Icon(Icons.schedule_rounded, color: c.onSurfaceVariant),
      );
    } else {
      trailing = IconButton(
        tooltip: failed ?? 'Download',
        onPressed: () {
          try {
            ref.read(downloadsProvider.notifier).enqueue(entry, link, [chapter]);
          } catch (e) {
            showSnack(context, friendlyError(e), error: true);
          }
        },
        icon: Icon(
            failed != null ? Icons.error_outline_rounded : Icons.download_outlined,
            color: failed != null ? c.error : c.onSurfaceVariant),
      );
    }

    final sub = [
      if (showGroup) chapter.scanlatorLabel,
      if (chapter.uploadedAt != null) relativeTime(chapter.uploadedAt!),
      if (isLast && !link.lastFinished && link.lastPageCount != null)
        'page ${link.lastPage + 1} of ${link.lastPageCount}',
    ].join(' · ');

    return ListTile(
      onTap: open,
      onLongPress: () => _menu(context, ref, read),
      leading: isLast
          ? Icon(Icons.bookmark_rounded, color: c.primary)
          : Icon(read ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 20, color: read ? c.onSurfaceVariant : c.outline),
      title: Text(
        chapter.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: read && !isLast ? c.onSurfaceVariant : null,
          fontWeight: isLast ? FontWeight.w700 : null,
        ),
      ),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }

  void _menu(BuildContext context, WidgetRef ref, bool read) {
    final n = chapter.number;
    final entries = ref.read(entriesProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(chapter.name, maxLines: 2)),
          if (n != null && !read)
            ListTile(
              leading: const Icon(Icons.done_all_rounded),
              title: const Text('Mark read up to here'),
              onTap: () {
                Navigator.pop(ctx);
                entries.setChapter(entry, n.floor());
              },
            ),
          if (n != null && read)
            ListTile(
              leading: const Icon(Icons.remove_done_rounded),
              title: const Text('Mark unread from here'),
              onTap: () {
                Navigator.pop(ctx);
                final back = n.ceil() - 1;
                entries.setChapter(entry, back < 0 ? 0 : back);
              },
            ),
          if (chapter.url != null)
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('Open in browser'),
              onTap: () {
                Navigator.pop(ctx);
                launchUrl(Uri.parse(chapter.url!),
                    mode: LaunchMode.externalApplication);
              },
            ),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: c.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(children: [
            Icon(icon, color: c.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: context.text.bodySmall
                      ?.copyWith(color: c.onSecondaryContainer)),
            ),
            if (action != null) action!,
          ]),
        ),
      ),
    );
  }
}
