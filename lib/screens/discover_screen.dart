import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sources/mangadex_source.dart';
import '../services/sources/reader_source.dart';
import '../state/language_filter.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../widgets/updates_button.dart';
import 'discover_source_browser.dart';
import 'extension_store_screen.dart' show ExtensionStoreScreen, langName;

/// Discover: Trending / Popular / Top lists, search and a genre filter on
/// every reading source — MangaDex and your installed extensions — one at
/// a time, or all of them together ("All", the default).
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _scroll = ScrollController();
  final _browser = GlobalKey<SourceBrowserState>();

  /// Shown once you've scrolled about two screens down.
  static const _topButtonAfter = 1200.0;
  bool _showTop = false;

  /// Where Discover looks: null = all sources, or one source's id.
  String? _sourceId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final show = pos.pixels > _topButtonAfter;
    if (show != _showTop) setState(() => _showTop = show);
    if (pos.extentAfter < 600) _browser.currentState?.loadMore();
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // MangaDex and your installed extensions, in your reading language.
    final lang = ref.watch(contentLanguageProvider);
    final sources = [
      for (final s in ref.watch(readerSourcesProvider).primary)
        if (matchesLanguage(lang, s.lang)) s,
    ];
    // The chosen extension was removed or is in another language now:
    // back to all sources.
    final source = sources.where((s) => s.id == _sourceId).firstOrNull;

    return Scaffold(
      floatingActionButton: AnimatedScale(
        scale: _showTop ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: FloatingActionButton.small(
          heroTag: 'discover-top',
          tooltip: 'Scroll to top',
          onPressed: _showTop ? _toTop : null,
          child: const Icon(Icons.vertical_align_top_rounded),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _browser.currentState?.refresh(),
        child: CustomScrollView(
          controller: _scroll,
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
                      source == null
                          ? 'All sources'
                          : 'Browsing ${source.name}',
                      style: context.text.labelLarge
                          ?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text('Discover', style: context.text.headlineSmall),
                ],
              ),
              actions: const [UpdatesButton(), SizedBox(width: 8)],
            ),
            SliverToBoxAdapter(
              child: _SourceBar(
                sources: sources,
                selected: source,
                language: lang,
                onSelected: (s) {
                  if (s?.id == source?.id) return;
                  setState(() => _sourceId = s?.id);
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
              ),
            ),
            SourceBrowser(
              key: _browser,
              sources: source == null ? sources : [source],
              allSources: source == null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The row of places Discover can look in: all of them, then MangaDex and
/// your installed extensions (only ones in your reading language).
class _SourceBar extends StatelessWidget {
  const _SourceBar({
    required this.sources,
    required this.selected,
    required this.language,
    required this.onSelected,
  });

  final List<ReaderSource> sources;
  final ReaderSource? selected;
  final String? language;
  final void Function(ReaderSource?) onSelected;

  @override
  Widget build(BuildContext context) {
    final extensions =
        sources.where((s) => s.id != MangaDexSource.sourceId).length;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              avatar: const Icon(Icons.all_inclusive_rounded, size: 18),
              label: Text('All  ${sources.length}'),
              tooltip: 'Browse and search every source at once',
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final s in sources)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(
                    s.id == MangaDexSource.sourceId
                        ? Icons.menu_book_rounded
                        : Icons.extension_rounded,
                    size: 18),
                label: Text(language == null && s.lang != 'all'
                    ? '${s.name} · ${langName(s.lang)}'
                    : s.name),
                selected: selected?.id == s.id,
                onSelected: (_) => onSelected(s),
              ),
            ),
          if (extensions == 0)
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: Text(language == null
                  ? 'Add extensions'
                  : 'Add ${langName(language!)} extensions'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const ExtensionStoreScreen())),
            ),
        ],
      ),
    );
  }
}
