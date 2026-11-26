import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/dates.dart';
import '../widgets/add_title_sheet.dart';
import '../widgets/common.dart';
import '../widgets/entry_card.dart';

/// Library tab (everything except To Read) and the To Read tab.
class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key, required this.tab});
  final ListTab tab;

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isLibrary => widget.tab == ListTab.library;

  StateController<ListQuery> get _query =>
      ref.read(listQueryProvider(widget.tab).notifier);

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(entriesProvider);
    final query = ref.watch(listQueryProvider(widget.tab));
    final visible = ref.watch(visibleEntriesProvider(widget.tab));
    final counts = ref.watch(statusCountsProvider);

    final totalInTab = _isLibrary
        ? counts.entries
            .where((e) => e.key != EntryStatus.toRead)
            .fold<int>(0, (a, e) => a + e.value)
        : counts[EntryStatus.toRead] ?? 0;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-${widget.tab.name}',
        onPressed: () => showAddTitleSheet(context,
            status: _isLibrary ? EntryStatus.reading : EntryStatus.toRead),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add title'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(entriesProvider.notifier).refresh(manual: true);
          // Pulled to refresh with no connection: say why nothing changed.
          if (context.mounted && !ref.read(onlineProvider)) {
            showOfflineToast(context, force: true);
          }
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _Header(tab: widget.tab, query: query, total: totalInTab),
            // Checking chapters, finding covers and downloads show as quiet
            // notifications; being offline is a small icon in the header
            // plus a short toast when the connection drops.
            if (_isLibrary && totalInTab > 0)
              const SliverToBoxAdapter(child: _SummaryStrip()),
            if (totalInTab > 0) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (v) =>
                        _query.state = _query.state.copyWith(search: v),
                    decoration: InputDecoration(
                      hintText: _isLibrary
                          ? 'Search your library'
                          : 'Search your To Read pile',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: query.search.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _search.clear();
                                _query.state =
                                    _query.state.copyWith(search: '');
                              },
                            ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _FilterBar(tab: widget.tab, query: query, counts: counts),
              ),
            ],
            ..._body(context, async, query, visible, totalInTab),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AsyncValue<List<Entry>> async,
      ListQuery query, List<Entry> visible, int totalInTab) {
    if (async.isLoading && !async.hasValue) {
      return [const SliverToBoxAdapter(child: _SkeletonList())];
    }
    if (async.hasError && !async.hasValue) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.error_outline_rounded,
            title: "Couldn't load your list",
            message: friendlyError(async.error!),
            action: FilledButton(
              onPressed: () => ref.invalidate(entriesProvider),
              child: const Text('Try again'),
            ),
          ),
        ),
      ];
    }
    if (totalInTab == 0) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _isLibrary
              ? EmptyState(
                  icon: Icons.auto_stories_rounded,
                  title: 'Start your library',
                  message:
                      'Add what you’re reading, then tap Resume to read it here — online or from downloads.',
                  action: FilledButton.icon(
                    onPressed: () => showAddTitleSheet(context),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add your first title'),
                  ),
                )
              : EmptyState(
                  icon: Icons.bookmark_add_outlined,
                  title: 'Nothing queued up',
                  message:
                      'Save titles you want to read later. Find ideas in Discover.',
                  action: FilledButton.icon(
                    onPressed: () =>
                        showAddTitleSheet(context, status: EntryStatus.toRead),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add to To Read'),
                  ),
                ),
        ),
      ];
    }
    if (visible.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.filter_alt_off_rounded,
            title: 'No matches',
            message: 'Nothing fits these filters.',
            action: OutlinedButton(
              onPressed: () {
                _search.clear();
                _query.state = ListQuery(sort: query.sort, grid: query.grid);
              },
              child: const Text('Clear filters'),
            ),
          ),
        ),
      ];
    }

    if (query.grid) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              childAspectRatio: 0.66,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: visible.length,
            itemBuilder: (_, i) => EntryGridCard(entry: visible[i]),
          ),
        ),
      ];
    }

    if (query.canReorder) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          sliver: SliverReorderableList(
            itemCount: visible.length,
            // onReorderItem already adjusts newIndex for the removed item.
            onReorderItem: (oldIndex, newIndex) async {
              if (newIndex == oldIndex) return;
              try {
                await ref
                    .read(entriesProvider.notifier)
                    .reorder(visible[oldIndex].id, visible[newIndex].id);
              } catch (e) {
                if (context.mounted) {
                  showSnack(context, friendlyError(e), error: true);
                }
              }
            },
            itemBuilder: (context, i) {
              final e = visible[i];
              return Padding(
                key: ValueKey(e.id),
                padding: const EdgeInsets.only(bottom: 10),
                child: EntryTile(
                  entry: e,
                  dragHandle: ReorderableDragStartListener(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(Icons.drag_indicator_rounded,
                          color: context.colors.onSurfaceVariant),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        sliver: SliverList.builder(
          itemCount: visible.length,
          itemBuilder: (_, i) => Padding(
            key: ValueKey(visible[i].id),
            padding: const EdgeInsets.only(bottom: 10),
            child: EntryTile(entry: visible[i]),
          ),
        ),
      ),
    ];
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.tab, required this.query, required this.total});

  final ListTab tab;
  final ListQuery query;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final isLibrary = tab == ListTab.library;
    final controller = ref.read(listQueryProvider(tab).notifier);
    final online = ref.watch(onlineProvider);

    return SliverAppBar(
      floating: true,
      snap: true,
      toolbarHeight: 84,
      titleSpacing: 20,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isLibrary
                ? timeGreeting()
                : '$total saved for later',
            style: context.text.labelLarge?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(isLibrary ? 'Your library' : 'To Read',
              style: context.text.headlineSmall),
        ],
      ),
      actions: [
        if (!online)
          IconButton(
            tooltip: "Offline — tap to try again",
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await ref.read(entriesProvider.notifier).refresh();
              if (context.mounted && !ref.read(onlineProvider)) {
                showOfflineToast(context, force: true);
              }
            },
            icon: Icon(Icons.cloud_off_rounded,
                size: 20, color: c.onSurfaceVariant),
          ),
        if (total > 0) ...[
          IconButton(
            tooltip: query.grid ? 'List view' : 'Grid view',
            onPressed: () =>
                controller.state = controller.state.copyWith(grid: !query.grid),
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                query.grid ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
                key: ValueKey(query.grid),
              ),
            ),
          ),
          PopupMenuButton<SortOption>(
            tooltip: 'Sort',
            icon: const Icon(Icons.swap_vert_rounded),
            initialValue: query.sort,
            onSelected: (s) =>
                controller.state = controller.state.copyWith(sort: s),
            itemBuilder: (_) => [
              for (final s in SortOption.values)
                PopupMenuItem(
                  value: s,
                  child: Row(children: [
                    Icon(s.icon,
                        size: 20,
                        color: s == query.sort ? c.primary : c.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Text(s.label,
                        style: TextStyle(
                            fontWeight: s == query.sort
                                ? FontWeight.w700
                                : FontWeight.w400)),
                  ]),
                ),
            ],
          ),
        ],
        const SizedBox(width: 8),
      ],
    );
  }
}

/// Three quick numbers at the top of the library.
class _SummaryStrip extends ConsumerWidget {
  const _SummaryStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final counts = ref.watch(statusCountsProvider);
    final chapters = entries.fold<int>(0, (a, e) => a + e.chapter);
    final sc = context.statusColors;

    Widget tile(String label, String value, Color color, IconData icon) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(height: 10),
                Text(value, style: context.text.titleLarge),
                Text(label,
                    style: context.text.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant)),
              ],
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        tile('Reading', '${counts[EntryStatus.reading]}',
            sc.of(EntryStatus.reading), Icons.auto_stories_rounded),
        const SizedBox(width: 10),
        tile('Finished', '${counts[EntryStatus.finished]}',
            sc.of(EntryStatus.finished), Icons.task_alt_rounded),
        const SizedBox(width: 10),
        tile('Chapters', _compact(chapters), context.colors.primary,
            Icons.menu_book_rounded),
      ]),
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar(
      {required this.tab, required this.query, required this.counts});

  final ListTab tab;
  final ListQuery query;
  final Map<EntryStatus, int> counts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(listQueryProvider(tab).notifier);
    final c = context.colors;
    final sc = context.statusColors;

    final chips = <Widget>[];
    if (tab == ListTab.library) {
      chips.add(ChoiceChip(
        label: const Text('All'),
        selected: query.status == null,
        onSelected: (_) => controller.state =
            controller.state.copyWith(status: const Nullable(null)),
      ));
      for (final s in EntryStatus.library) {
        final n = counts[s] ?? 0;
        if (n == 0 && query.status != s) continue;
        chips.add(ChoiceChip(
          avatar: CircleAvatar(backgroundColor: sc.of(s), radius: 4),
          label: Text('${s.label}  $n'),
          selected: query.status == s,
          selectedColor: sc.of(s).withValues(alpha: 0.18),
          side: BorderSide(
              color: query.status == s ? sc.of(s) : c.outlineVariant),
          onSelected: (sel) => controller.state = controller.state
              .copyWith(status: Nullable(sel ? s : null)),
        ));
      }
    }

    // Type filter as a compact dropdown chip.
    // (String values because PopupMenuButton treats a null value as "cancelled".)
    chips.add(PopupMenuButton<String>(
      tooltip: 'Filter by type',
      onSelected: (v) => controller.state = controller.state
          .copyWith(type: Nullable(EntryType.tryParse(v))),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'all', child: Text('All types')),
        for (final t in EntryType.values)
          PopupMenuItem(value: t.label, child: Text(t.label)),
      ],
      child: Chip(
        avatar: Icon(Icons.category_outlined,
            size: 16, color: query.type != null ? c.primary : null),
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(query.type?.label ?? 'All types'),
          const Icon(Icons.arrow_drop_down_rounded, size: 20),
        ]),
        backgroundColor:
            query.type != null ? c.primary.withValues(alpha: 0.18) : null,
      ),
    ));

    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }
}

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_anim),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: List.generate(
            5,
            (_) => Container(
              height: 102,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: c.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
