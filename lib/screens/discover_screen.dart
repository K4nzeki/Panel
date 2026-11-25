import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../services/anilist.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../widgets/add_title_sheet.dart';
import '../widgets/common.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _scroll = ScrollController();
  DiscoverSort _sort = DiscoverSort.trending;
  EntryType? _type;

  final List<SearchResult> _results = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
    });
    _reset();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _requestId++;
    setState(() {
      _results.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final id = _requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(aniListProvider)
          .discover(_sort, _page + 1, type: _type);
      if (!mounted || id != _requestId) return;
      setState(() {
        _page++;
        final seen = _results.map((r) => r.id).toSet();
        _results.addAll(page.results.where((r) => seen.add(r.id)));
        _hasMore = page.hasNextPage;
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
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final inList = {for (final e in entries) e.title.trim().toLowerCase()};
    final c = context.colors;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => _reset(),
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
                  Text('Powered by AniList',
                      style: context.text.labelLarge
                          ?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text('Discover', style: context.text.headlineSmall),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => showAddTitleSheet(context,
                      status: EntryStatus.toRead),
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: SegmentedButton<DiscoverSort>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: DiscoverSort.trending,
                        icon: Icon(Icons.local_fire_department_outlined),
                        label: Text('Trending')),
                    ButtonSegment(
                        value: DiscoverSort.popular,
                        icon: Icon(Icons.favorite_outline_rounded),
                        label: Text('Popular')),
                    ButtonSegment(
                        value: DiscoverSort.topRated,
                        icon: Icon(Icons.star_outline_rounded),
                        label: Text('Top')),
                  ],
                  selected: {_sort},
                  onSelectionChanged: (s) {
                    _sort = s.first;
                    _reset();
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  children: [
                    for (final t in <EntryType?>[
                      null,
                      EntryType.manga,
                      EntryType.manhwa,
                      EntryType.manhua
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(t?.label ?? 'All'),
                          selected: _type == t,
                          onSelected: (_) {
                            if (_type == t) return;
                            _type = t;
                            _reset();
                          },
                        ),
                      ),
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
                  title: "Couldn't load titles",
                  message: _error!,
                  action: FilledButton(
                      onPressed: _reset, child: const Text('Try again')),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    childAspectRatio: 0.5,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final r = _results[i];
                    return _DiscoverCard(
                      result: r,
                      rank: _sort == DiscoverSort.trending ? i + 1 : null,
                      inList: inList.contains(r.title.trim().toLowerCase()),
                      onTap: () => showResultPreview(context, r),
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
                              onPressed: _loadMore,
                              child: const Text('Couldn’t load more — retry'))
                          : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({
    required this.result,
    required this.inList,
    required this.onTap,
    this.rank,
  });

  final SearchResult result;
  final bool inList;
  final VoidCallback onTap;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = result;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CoverImage(url: r.coverUrl, title: r.title, radius: 16),
                if (r.averageScore != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _Pill(
                      icon: Icons.star_rounded,
                      text: '${r.averageScore}%',
                    ),
                  ),
                if (rank != null && rank! <= 10)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _Pill(text: '#$rank'),
                  ),
                if (inList)
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
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(r.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelLarge?.copyWith(height: 1.2)),
          const SizedBox(height: 2),
          Text(
            [
              r.type.label,
              if (r.totalChapters != null) '${r.totalChapters} ch',
            ].join(' · '),
            maxLines: 1,
            style: context.text.labelSmall?.copyWith(color: c.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: const Color(0xFFFFC94D)),
            const SizedBox(width: 3),
          ],
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
        ]),
      );
}

/// Details for an AniList title with quick "add" actions.
Future<void> showResultPreview(BuildContext context, SearchResult r) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Consumer(
        builder: (context, ref, _) {
          final c = context.colors;
          final entries =
              ref.watch(entriesProvider).value ?? const <Entry>[];
          final existing = entries.where(
              (e) => e.title.trim().toLowerCase() == r.title.trim().toLowerCase());

          Future<void> add(EntryStatus s) async {
            final ok = await addResult(context, ref, r, s);
            if (ok && context.mounted) Navigator.of(context).pop();
          }

          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CoverImage(
                      url: r.coverUrl, title: r.title, width: 110, height: 158),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.title,
                            style:
                                context.text.titleLarge?.copyWith(height: 1.2)),
                        if (r.author != null) ...[
                          const SizedBox(height: 4),
                          Text(r.author!,
                              style: context.text.bodyMedium
                                  ?.copyWith(color: c.onSurfaceVariant)),
                        ],
                        const SizedBox(height: 10),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          TagChip(r.type.label),
                          if (r.publicationStatus != null)
                            TagChip(r.publicationStatus!),
                          if (r.totalChapters != null)
                            TagChip('${r.totalChapters} chapters'),
                          if (r.averageScore != null)
                            TagChip('${r.averageScore}%',
                                icon: Icons.star_rounded),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (existing.isNotEmpty)
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
                        child: Text(
                            'In your list · ${existing.first.status.label}')),
                  ]),
                )
              else
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
              if (r.description != null && r.description!.isNotEmpty) ...[
                const SectionLabel('Synopsis'),
                Text(r.description!,
                    style: context.text.bodyMedium?.copyWith(height: 1.5)),
              ],
            ],
          );
        },
      ),
    ),
  );
}
