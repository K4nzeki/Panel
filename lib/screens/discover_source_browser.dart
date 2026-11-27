import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/mangadex.dart';
import '../services/sources/mangadex_source.dart';
import '../services/sources/reader_source.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/entry_card.dart' show confirmRemoveFromList, deleteWithUndo;
import '../widgets/entry_sheet.dart' show confirm;
import 'chapters_screen.dart' show openChapters;
import 'extension_store_screen.dart' show langName;

/// One result in Discover, with the source it came from.
class BrowseHit {
  const BrowseHit(this.source, this.series);
  final ReaderSource source;
  final SourceSeries series;
}

/// Mixes the pages several sources returned into one list: one from each
/// source in turn, so no single source fills the top. Drops titles already
/// in [seen] (normalised titles), and adds the new ones to it. Public for
/// tests.
List<BrowseHit> interleaveHits(
    List<(ReaderSource, List<SourceSeries>)> pages, Set<String> seen) {
  final out = <BrowseHit>[];
  var i = 0;
  var added = true;
  while (added) {
    added = false;
    for (final (source, series) in pages) {
      if (i >= series.length) continue;
      added = true;
      final s = series[i];
      final key = normalizeTitle(s.title);
      if (seen.add(key.isEmpty ? '${source.id}\n${s.key}' : key)) {
        out.add(BrowseHit(source, s));
      }
    }
    i++;
  }
  return out;
}

/// Discover's lists for one reading source, or for all of them at once
/// ([allSources]): Trending / Popular / Top, search, and a genre filter.
/// Tap a title to add it (linked to its source) or open it; long-press one
/// that's in your list to remove it.
///
/// Loads more pages as you scroll ([loadMore], called by Discover's scroll
/// view). With several sources, each page asks every source at once and
/// mixes the results; sources that fail or can't filter by the chosen
/// genre are left out and named under the chips.
class SourceBrowser extends ConsumerStatefulWidget {
  const SourceBrowser(
      {super.key, required this.sources, this.allSources = false});

  final List<ReaderSource> sources;
  final bool allSources;

  @override
  ConsumerState<SourceBrowser> createState() => SourceBrowserState();
}

class SourceBrowserState extends ConsumerState<SourceBrowser> {
  static const _timeout = Duration(seconds: 25);

  final _query = TextEditingController();
  final List<BrowseHit> _results = [];
  final Set<String> _seen = {};

  /// Sources with no more pages (or that failed, or can't do the genre).
  final Set<String> _done = {};
  final List<String> _failed = [];
  final List<String> _noGenre = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  BrowseSort _sort = BrowseSort.trending;
  String? _genre;

  /// What the list shows now: '' = the [_sort] list.
  String _shownQuery = '';

  List<ReaderSource> get _sources => widget.sources;

  static String _signature(List<ReaderSource> l) =>
      [for (final s in l) s.id].join('\n');

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void didUpdateWidget(SourceBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_signature(oldWidget.sources) != _signature(widget.sources)) {
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
    _seen.clear();
    _done.clear();
    _failed.clear();
    _noGenre.clear();
    _page = 0;
    _error = null;
    _loading = false;
    _hasMore = true;
    if (mounted) setState(() {});
    loadMore();
  }

  /// Runs the current search (or list) again.
  void refresh() => _run(_shownQuery);

  Future<(ReaderSource, BrowsePage?, Object?)> _fetch(
      ReaderSource s, String q, int page) async {
    try {
      final p = await (s as BrowsableSource)
          .browse(sort: _sort, query: q, genre: _genre, page: page)
          .timeout(_timeout);
      return (s, p, null);
    } on TimeoutException {
      return (s, null, SourceException('${s.name} is taking too long.'));
    } catch (e) {
      return (s, null, e);
    }
  }

  /// Loads the next page, if there is one. Safe to call often.
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    final active = [
      for (final s in _sources)
        if (s is BrowsableSource && !_done.contains(s.id)) s,
    ];
    if (active.isEmpty) {
      setState(() => _hasMore = false);
      return;
    }
    final id = _requestId;
    final q = _shownQuery;
    final page = _page + 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    final answers = await Future.wait([for (final s in active) _fetch(s, q, page)]);
    if (!mounted || id != _requestId) return;

    final pages = <(ReaderSource, List<SourceSeries>)>[];
    Object? firstError;
    for (final (source, result, err) in answers) {
      if (result == null) {
        firstError ??= err;
        _done.add(source.id);
        // A single source shows its error itself; with several, name it.
        if (widget.allSources) _failed.add(source.name);
        continue;
      }
      if (_genre != null && !result.genreApplied) {
        _done.add(source.id);
        _noGenre.add(source.name);
        continue;
      }
      if (!result.hasNextPage || result.series.isEmpty) _done.add(source.id);
      pages.add((source, result.series));
    }
    final found = interleaveHits(pages, _seen);
    setState(() {
      _page = page;
      _results.addAll(found);
      _loading = false;
      _hasMore = _sources.any((s) => s is BrowsableSource && !_done.contains(s.id));
      if (pages.isEmpty && firstError != null && _results.isEmpty) {
        _error = friendlyError(firstError);
      } else if (firstError != null && !widget.allSources) {
        _error = friendlyError(firstError);
      }
    });
    // Everything on this page was a duplicate: try the next one.
    if (found.isEmpty && _hasMore && _error == null) unawaited(loadMore());
  }

  Future<void> _pickGenre() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Genre', style: ctx.text.titleMedium),
              const SizedBox(height: 4),
              Text(
                  widget.allSources
                      ? 'Sources that can’t filter by genre are left out.'
                      : 'Not every source can filter by every genre.',
                  style: ctx.text.bodySmall
                      ?.copyWith(color: ctx.colors.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ChoiceChip(
                  label: const Text('Any genre'),
                  selected: _genre == null,
                  onSelected: (_) => Navigator.pop(ctx, ''),
                ),
                for (final g in browseGenres)
                  ChoiceChip(
                    label: Text(g),
                    selected: _genre == g,
                    onSelected: (_) => Navigator.pop(ctx, g),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final next = picked.isEmpty ? null : picked;
    if (next == _genre) return;
    _genre = next;
    _run(_shownQuery);
  }

  /// Long-press: remove a title that's in your list (after asking), or
  /// show the preview for one that isn't.
  Future<void> _longPress(BrowseHit hit) async {
    final t = hit.series.title.trim().toLowerCase();
    final entry = (ref.read(entriesProvider).value ?? const <Entry>[])
        .where((e) => e.title.trim().toLowerCase() == t)
        .firstOrNull;
    if (entry == null) {
      await showSourceSeriesPreview(context, hit.source, hit.series);
      return;
    }
    await confirmRemoveFromList(context, ref, entry);
  }

  String _heading() {
    final where = widget.allSources
        ? 'across ${_sources.length} source${_sources.length == 1 ? '' : 's'}'
        : 'on ${_sources.firstOrNull?.name ?? ''}';
    final genre = _genre == null ? '' : ' · $_genre';
    if (_shownQuery.isNotEmpty) return 'Results for “$_shownQuery”$genre';
    return '${_sort.label}$genre $where';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inList = ref.watch(libraryTitlesProvider);
    final single = widget.allSources ? null : _sources.firstOrNull;
    final name = single?.name ?? 'all sources';
    final notes = [
      if (_noGenre.isNotEmpty)
        'Can’t filter by genre, left out: ${_noGenre.join(', ')}.',
      if (_failed.isNotEmpty) 'Couldn’t load: ${_failed.join(', ')}.',
    ];

    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: _run,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search $name',
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
      SliverToBoxAdapter(
        child: SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            children: [
              for (final s in BrowseSort.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: Icon(
                        switch (s) {
                          BrowseSort.trending =>
                            Icons.local_fire_department_outlined,
                          BrowseSort.popular => Icons.favorite_outline_rounded,
                          BrowseSort.top => Icons.star_outline_rounded,
                        },
                        size: 18),
                    label: Text(s.label),
                    selected: _sort == s,
                    onSelected: (_) {
                      if (_sort == s) return;
                      _sort = s;
                      _run(_shownQuery);
                    },
                  ),
                ),
              FilterChip(
                avatar: const Icon(Icons.tune_rounded, size: 18),
                label: Text(_genre ?? 'Genre'),
                selected: _genre != null,
                showCheckmark: false,
                onSelected: (_) => _pickGenre(),
                onDeleted: _genre == null
                    ? null
                    : () {
                        _genre = null;
                        _run(_shownQuery);
                      },
              ),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_heading(), style: context.text.titleSmall),
              for (final n in notes)
                Text(n,
                    style: context.text.labelSmall
                        ?.copyWith(color: c.onSurfaceVariant)),
            ],
          ),
        ),
      ),
      if (_results.isEmpty && _loading)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_results.isEmpty && _error != null)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load ${single?.name ?? 'titles'}",
            message: _error!,
            action: FilledButton(
                onPressed: refresh, child: const Text('Try again')),
          ),
        )
      else if (_results.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No results',
            message: _shownQuery.isEmpty
                ? 'Nothing to show here right now. Try another list or genre.'
                : 'Nothing called “$_shownQuery” on $name.',
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
              final hit = _results[i];
              final s = hit.series;
              final added = inList.contains(s.title.trim().toLowerCase());
              final sub = widget.allSources ? hit.source.name : s.subtitle;
              return GestureDetector(
                onTap: () => showSourceSeriesPreview(context, hit.source, s),
                onLongPress: () => _longPress(hit),
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
                            child: Tooltip(
                              message: 'In your list · long-press to remove',
                              child: CircleAvatar(
                                radius: 13,
                                backgroundColor: c.primary,
                                child: Icon(Icons.check_rounded,
                                    size: 16, color: c.onPrimary),
                              ),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Text(s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.labelLarge?.copyWith(height: 1.2)),
                    if (sub != null && sub.isNotEmpty)
                      Text(sub,
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
                : _error != null && _results.isNotEmpty && !widget.allSources
                    ? TextButton(
                        onPressed: () {
                          // Let the failed source try this page again.
                          _done.remove(single?.id);
                          setState(() => _hasMore = true);
                          loadMore();
                        },
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
        // No cover yet: take the one from this source.
        unawaited(ref
            .read(entriesProvider.notifier)
            .fillCoverFromSource(entry.id)
            .catchError((_) {}));
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

      Future<void> removeExisting(Entry entry) async {
        final ok = await confirm(sheetContext,
            title: 'Remove “${entry.title}” from your list?',
            message: 'Its progress and the chapters it added to Stats are '
                'removed too. You can undo right after.',
            action: 'Remove',
            destructive: true);
        if (ok != true || !sheetContext.mounted) return;
        Navigator.of(sheetContext).pop();
        if (context.mounted) await deleteWithUndo(context, ref, entry);
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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: c.error,
                side: BorderSide(color: c.error.withValues(alpha: 0.4)),
              ),
              onPressed: () => removeExisting(existing),
              icon: const Icon(Icons.bookmark_remove_outlined),
              label: const Text('Remove from list'),
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
