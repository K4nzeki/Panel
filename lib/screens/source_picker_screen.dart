import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../screens/extension_store_screen.dart' show langName;
import '../services/sources/reader_source.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../widgets/common.dart';

class PickedSource {
  const PickedSource(this.source, this.series);
  final ReaderSource source;
  final SourceSeries series;
}

/// Searches MangaDex and the sites of your installed extensions for a
/// title, side by side, so you can pick where to read it. Other sites from
/// your repos can be added to the search.
class SourcePickerScreen extends ConsumerStatefulWidget {
  const SourcePickerScreen({super.key, required this.entry});
  final Entry entry;

  @override
  ConsumerState<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends ConsumerState<SourcePickerScreen> {
  late final _query = TextEditingController(text: widget.entry.title);
  final _moreFilter = TextEditingController();
  late List<ReaderSource> _sources;
  final Map<String, Future<List<SourceSeries>>> _searches = {};

  /// Set once a result was picked, so a double tap can't pop twice (which
  /// would also close the chapters screen underneath).
  bool _picked = false;

  @override
  void initState() {
    super.initState();
    final registry = ref.read(readerSourcesProvider);
    _sources = [...registry.primary];
    // The current source (maybe one that's no longer installed) goes first.
    final link = ref.read(readingLinksProvider)[widget.entry.id];
    if (link != null) {
      try {
        final current = registry.forLink(link);
        _sources.removeWhere((s) => s.id == current.id);
        _sources.insert(0, current);
      } catch (_) {
        // A broken saved link must not stop you from picking a new source.
      }
    }
    // Native extensions finish loading after app start: add the ones that
    // show up while this screen is open instead of never searching them.
    ref.listenManual(readerSourcesProvider, (_, next) {
      if (!mounted) return;
      final fresh = [
        for (final s in next.primary)
          if (!_sources.any((x) => x.id == s.id)) s,
      ];
      if (fresh.isEmpty) return;
      setState(() {
        _sources.addAll(fresh);
        for (final s in fresh) {
          _searches[s.id] = _safeSearch(s, _query.text);
        }
      });
    });
    _runSearches();
  }

  @override
  void dispose() {
    _query.dispose();
    _moreFilter.dispose();
    super.dispose();
  }

  /// A source that throws straight away (instead of returning a failed
  /// future) shows its error in its row rather than breaking the screen.
  static Future<List<SourceSeries>> _safeSearch(ReaderSource s, String q) {
    try {
      return s.search(q);
    } catch (e, st) {
      return Future.error(e, st);
    }
  }

  void _runSearches() {
    _searches.clear();
    for (final s in _sources) {
      _searches[s.id] = _safeSearch(s, _query.text);
    }
  }

  void _searchAll() => setState(_runSearches);

  void _add(ReaderSource s) => setState(() {
        if (!_sources.any((x) => x.id == s.id)) _sources.insert(0, s);
        _searches[s.id] = _safeSearch(s, _query.text);
      });

  void _pick(ReaderSource s, SourceSeries series) {
    if (_picked || !mounted) return;
    _picked = true;
    Navigator.of(context).pop(PickedSource(s, series));
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(readerSourcesProvider);
    final currentId = ref.watch(
        readingLinksProvider.select((m) => m[widget.entry.id]?.sourceId));
    final c = context.colors;
    final filter = _moreFilter.text.trim().toLowerCase();
    final more = [
      for (final s in registry.available)
        if (!_sources.any((x) => x.id == s.id) &&
            (filter.isEmpty || s.name.toLowerCase().contains(filter)))
          s,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a source')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchAll(),
              decoration: InputDecoration(
                hintText: 'Search title',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: _searchAll,
                ),
              ),
            ),
          ),
          if (registry.installed.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Searching MangaDex. Install extensions (Settings → Extension '
                'store) to search their sites too, or add a site from '
                '"More sources" below.',
                style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
              ),
            ),
          for (final s in _sources)
            _SourceResults(
              source: s,
              current: s.id == currentId,
              future: _searches[s.id],
              onPick: (series) => _pick(s, series),
            ),
          if (registry.available.isNotEmpty)
            ExpansionTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: const Text('More sources'),
              subtitle: Text('${registry.available.length} other sites from your repos'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _moreFilter,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Filter sites',
                      prefixIcon: Icon(Icons.filter_list_rounded),
                    ),
                  ),
                ),
                for (final s in more.take(60))
                  ListTile(
                    dense: true,
                    title: Text(s.name),
                    subtitle: Text('${langName(s.lang)} · ${s.base}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.search_rounded),
                    onTap: () => _add(s),
                  ),
                if (more.length > 60)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Type to find more…',
                        style: context.text.bodySmall
                            ?.copyWith(color: c.onSurfaceVariant)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SourceResults extends StatelessWidget {
  const _SourceResults({
    required this.source,
    required this.future,
    required this.onPick,
    this.current = false,
  });

  final ReaderSource source;
  final Future<List<SourceSeries>>? future;
  final void Function(SourceSeries) onPick;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Flexible(
                child: Text(source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.titleSmall),
              ),
              const SizedBox(width: 8),
              TagChip(langName(source.lang)),
              if (current) ...[
                const SizedBox(width: 6),
                const TagChip('Current', icon: Icons.check_rounded),
              ],
            ]),
          ),
          const SizedBox(height: 6),
          FutureBuilder<List<SourceSeries>>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text(friendlyError(snap.error!),
                      style: context.text.bodySmall?.copyWith(color: c.error)),
                );
              }
              final list = snap.data ?? const <SourceSeries>[];
              if (list.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text('No results',
                      style: context.text.bodySmall
                          ?.copyWith(color: c.onSurfaceVariant)),
                );
              }
              return SizedBox(
                height: 212,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return SizedBox(
                      width: 110,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onPick(s),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CoverImage(
                                url: s.coverUrl,
                                title: s.title,
                                width: 110,
                                height: 156),
                            const SizedBox(height: 6),
                            Text(s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.labelMedium),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
