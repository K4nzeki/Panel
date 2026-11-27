import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/mangadex.dart';
import '../services/sources/apk_source.dart';
import '../services/sources/mangadex_source.dart';
import '../services/sources/reader_source.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chapters_screen.dart' show openChapters;
import 'extension_store_screen.dart' show langName;

/// Discover's view of one reading source (MangaDex or an installed
/// extension): search it, and add a series to your list already linked to
/// that source, so Read opens it there.
///
/// Native extensions show their popular titles before you search and load
/// more pages as you scroll ([loadMore], called by Discover's scroll view).
class SourceBrowser extends ConsumerStatefulWidget {
  const SourceBrowser({super.key, required this.source});
  final ReaderSource source;

  @override
  ConsumerState<SourceBrowser> createState() => SourceBrowserState();
}

class SourceBrowserState extends ConsumerState<SourceBrowser> {
  final _query = TextEditingController();
  final List<SourceSeries> _results = [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  /// What the list shows now: '' = popular (native extensions only).
  String _shownQuery = '';

  ReaderSource get _source => widget.source;
  bool get _paged => _source is ApkSource;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void didUpdateWidget(SourceBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _query.clear();
      _run('');
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _run(String q) {
    _requestId++;
    _shownQuery = q.trim();
    _results.clear();
    _page = 0;
    _error = null;
    _loading = false;
    // Only native extensions can list popular titles without a search.
    _hasMore = _shownQuery.isNotEmpty || _paged;
    if (mounted) setState(() {});
    loadMore();
  }

  /// Runs the current search (or popular list) again.
  void refresh() => _run(_shownQuery);

  /// Loads the next page, if there is one. Safe to call often.
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    final id = _requestId;
    final q = _shownQuery;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<SourceSeries> found;
      final bool more;
      final s = _source;
      if (s is ApkSource) {
        final page = q.isEmpty
            ? await s.popular(page: _page + 1)
            : await s.searchPage(q, page: _page + 1);
        found = page.series;
        more = page.hasNextPage && page.series.isNotEmpty;
      } else {
        found = await s.search(q);
        more = false;
      }
      if (!mounted || id != _requestId) return;
      setState(() {
        _page++;
        final seen = _results.map((r) => r.key).toSet();
        _results.addAll(found.where((r) => seen.add(r.key)));
        _hasMore = more;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final inList = {for (final e in entries) e.title.trim().toLowerCase()};
    final waitingForQuery = _shownQuery.isEmpty && !_paged;

    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: _run,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search ${_source.name}',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _query.clear();
                        _run('');
                      },
                    ),
            ),
          ),
        ),
      ),
      if (_shownQuery.isEmpty && _paged && _results.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Popular on ${_source.name}',
                style: context.text.titleSmall),
          ),
        ),
      if (waitingForQuery)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.travel_explore_rounded,
            title: 'Search ${_source.name}',
            message: 'Type a title to find it on ${_source.name} '
                '(${langName(_source.lang)}). Adding it links your list to '
                'this source.',
          ),
        )
      else if (_results.isEmpty && _loading)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_results.isEmpty && _error != null)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load ${_source.name}",
            message: _error!,
            action: FilledButton(
                onPressed: () => _run(_shownQuery),
                child: const Text('Try again')),
          ),
        )
      else if (_results.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No results',
            message: _shownQuery.isEmpty
                ? '${_source.name} has nothing to show right now.'
                : 'Nothing called “$_shownQuery” on ${_source.name}.',
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              childAspectRatio: 0.52,
              mainAxisSpacing: 14,
              crossAxisSpacing: 12,
            ),
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final s = _results[i];
              final added = inList.contains(s.title.trim().toLowerCase());
              return GestureDetector(
                onTap: () => showSourceSeriesPreview(context, _source, s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Stack(fit: StackFit.expand, children: [
                        CoverImage(url: s.coverUrl, title: s.title, radius: 16),
                        if (added)
                          Positioned(
                            bottom: 6,
                            right: 6,
                            child: CircleAvatar(
                              radius: 13,
                              backgroundColor: c.primary,
                              child: Icon(Icons.check_rounded,
                                  size: 16, color: c.onPrimary),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Text(s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.labelLarge?.copyWith(height: 1.2)),
                    if (s.subtitle != null)
                      Text(s.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.labelSmall
                              ?.copyWith(color: c.onSurfaceVariant)),
                  ],
                ),
              );
            },
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: _loading && _results.isNotEmpty
                ? const CircularProgressIndicator()
                : _error != null && _results.isNotEmpty
                    ? TextButton(
                        onPressed: loadMore,
                        child: const Text('Couldn’t load more — retry'))
                    : const SizedBox.shrink(),
          ),
        ),
      ),
    ]);
  }
}

/// Manhwa for Korean sources, manhua for Chinese, otherwise manga. Only a
/// starting guess: it can be changed on the title.
EntryType _guessType(String lang) {
  final l = lang.toLowerCase();
  if (l.startsWith('ko')) return EntryType.manhwa;
  if (l.startsWith('zh')) return EntryType.manhua;
  return EntryType.manga;
}

/// A series found on [source]: add it to your list (linked to that source),
/// or, when it's already there, switch that title to read from here.
Future<void> showSourceSeriesPreview(
    BuildContext context, ReaderSource source, SourceSeries series) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => Consumer(builder: (ctx, ref, _) {
      final c = ctx.colors;
      final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
      final t = series.title.trim().toLowerCase();
      final existing =
          entries.where((e) => e.title.trim().toLowerCase() == t).firstOrNull;
      final link =
          existing == null ? null : ref.watch(readingLinksProvider)[existing.id];
      final linkedHere = link != null &&
          link.sourceId == source.id &&
          link.seriesKey == series.key;

      void linkTo(Entry entry) {
        ref.read(readingLinksProvider.notifier).choose(entry.id, source, series);
        // Like the source picker: reading on MangaDex also turns on alerts.
        if (source.id == MangaDexSource.sourceId && !entry.isLinked) {
          unawaited(ref
              .read(entriesProvider.notifier)
              .linkSource(
                entry,
                SourceManga(
                    id: series.key,
                    title: series.title,
                    coverUrl: series.coverUrl),
                keepCover: entry.coverUrl != null && entry.coverUrl!.isNotEmpty,
              )
              .catchError((_) {}));
        }
      }

      Future<void> add(EntryStatus status) async {
        try {
          final entry = await ref.read(entriesProvider.notifier).add(
                title: series.title,
                type: _guessType(source.lang),
                status: status,
                coverUrl: series.coverUrl,
                author: series.subtitle,
              );
          linkTo(entry);
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          if (!context.mounted) return;
          showSnack(context, 'Added “${series.title}” · reads on ${source.name}');
          if (status == EntryStatus.reading) {
            await openChapters(context, entry.id);
          }
        } catch (e) {
          if (context.mounted) showSnack(context, friendlyError(e), error: true);
        }
      }

      Future<void> readHere(Entry entry) async {
        if (!linkedHere) linkTo(entry);
        Navigator.of(sheetContext).pop();
        if (context.mounted) await openChapters(context, entry.id);
      }

      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverImage(
                url: series.coverUrl, title: series.title, width: 100, height: 144),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(series.title,
                      style: ctx.text.titleLarge?.copyWith(height: 1.2)),
                  if (series.subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(series.subtitle!,
                        style: ctx.text.bodyMedium
                            ?.copyWith(color: c.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    TagChip(source.name, icon: Icons.public_rounded),
                    TagChip(langName(source.lang)),
                  ]),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (existing != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Icon(Icons.check_circle_rounded, color: c.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(linkedHere
                      ? 'In your list · reads on ${source.name}'
                      : link == null
                          ? 'In your list · ${existing.status.label}'
                          : 'In your list · reads on ${link.sourceName}'),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => readHere(existing),
              icon: const Icon(Icons.auto_stories_rounded),
              label: Text(linkedHere ? 'Open chapters' : 'Read it on ${source.name}'),
            ),
          ] else
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => add(EntryStatus.toRead),
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('To Read'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => add(EntryStatus.reading),
                  icon: const Icon(Icons.auto_stories_rounded),
                  label: const Text('Start reading'),
                ),
              ),
            ]),
          if (series.url != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(series.url!),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open in browser'),
            ),
          ],
        ],
      );
    }),
  );
}
