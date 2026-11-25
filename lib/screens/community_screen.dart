import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/entry_card.dart';

/// Public profiles (RLS only returns readers who made their list public).
final publicProfilesProvider =
    FutureProvider.autoDispose<List<({String id, String username})>>(
        (ref) async {
  final db = ref.watch(supabaseProvider);
  final self = ref.watch(userIdProvider);
  var q = db.from('profiles').select('id, username').not('username', 'is', null);
  if (self != null) q = q.neq('id', self);
  final rows = await q.order('username', ascending: true);
  return [
    for (final r in rows)
      (id: r['id'].toString(), username: r['username'].toString()),
  ];
});

final publicEntriesProvider =
    FutureProvider.autoDispose.family<List<Entry>, String>((ref, uid) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('entries')
      .select('id, title, type, chapter, status, cover_url, total_chapters, created_at')
      .eq('user_id', uid)
      .order('title', ascending: true)
      .limit(1000);
  return rows.map(Entry.fromJson).toList();
});

class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key});

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(publicProfilesProvider);
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Readers')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
            decoration: const InputDecoration(
              hintText: 'Find a reader',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.cloud_off_rounded,
              title: "Couldn't load readers",
              message: friendlyError(e),
              action: FilledButton(
                  onPressed: () => ref.invalidate(publicProfilesProvider),
                  child: const Text('Try again')),
            ),
            data: (people) {
              final list = people
                  .where((p) => p.username.toLowerCase().contains(_filter))
                  .toList();
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.people_outline_rounded,
                  title: 'No readers found',
                  message: 'Only readers who made their list public show up here.',
                );
              }
              return RefreshIndicator(
                onRefresh: () => ref.refresh(publicProfilesProvider.future),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final p = list[i];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: c.primary.withValues(alpha: 0.18),
                          child: Text(p.username[0].toUpperCase(),
                              style: TextStyle(
                                  color: c.primary,
                                  fontWeight: FontWeight.w800)),
                        ),
                        title: Text('@${p.username}'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PublicProfileScreen(
                                userId: p.id, username: p.username),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class PublicProfileScreen extends ConsumerStatefulWidget {
  const PublicProfileScreen(
      {super.key, required this.userId, required this.username});

  final String userId;
  final String username;

  @override
  ConsumerState<PublicProfileScreen> createState() =>
      _PublicProfileScreenState();
}

class _PublicProfileScreenState extends ConsumerState<PublicProfileScreen> {
  EntryStatus? _status;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(publicEntriesProvider(widget.userId));
    final sc = context.statusColors;
    final c = context.colors;

    return Scaffold(
      appBar: AppBar(title: Text('@${widget.username}')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'List unavailable',
          message: friendlyError(e),
        ),
        data: (entries) {
          if (entries.isEmpty) {
            return const EmptyState(
              icon: Icons.visibility_off_outlined,
              title: 'Nothing to show',
              message: 'This list is empty or has been made private.',
            );
          }
          final counts = {for (final s in EntryStatus.values) s: 0};
          for (final e in entries) {
            counts[e.status] = counts[e.status]! + 1;
          }
          final shown = _status == null
              ? entries
              : entries.where((e) => e.status == _status).toList();

          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${entries.length} titles',
                            style: context.text.titleMedium),
                        const SizedBox(height: 12),
                        StackedBarLite(counts: counts),
                      ],
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
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: const Text('All'),
                        selected: _status == null,
                        onSelected: (_) => setState(() => _status = null),
                      ),
                    ),
                    for (final s in EntryStatus.values)
                      if (counts[s]! > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: CircleAvatar(
                                backgroundColor: sc.of(s), radius: 4),
                            label: Text('${s.label}  ${counts[s]}'),
                            selected: _status == s,
                            onSelected: (sel) =>
                                setState(() => _status = sel ? s : null),
                          ),
                        ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverList.separated(
                itemCount: shown.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final e = shown[i];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(children: [
                        CoverImage(
                            url: e.coverUrl,
                            title: e.title,
                            width: 46,
                            height: 66),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.text.titleSmall),
                              const SizedBox(height: 6),
                              Row(children: [
                                StatusBadge(e.status, dense: true),
                                const SizedBox(width: 8),
                                Text(chapterLabel(e),
                                    style: context.text.labelSmall?.copyWith(
                                        color: c.onSurfaceVariant)),
                              ]),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// Compact status distribution bar used on public profiles.
class StackedBarLite extends StatelessWidget {
  const StackedBarLite({super.key, required this.counts});
  final Map<EntryStatus, int> counts;

  @override
  Widget build(BuildContext context) {
    final sc = context.statusColors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: Row(children: [
          for (final s in EntryStatus.values)
            if (counts[s]! > 0)
              Expanded(flex: counts[s]!, child: ColoredBox(color: sc.of(s))),
        ]),
      ),
    );
  }
}
