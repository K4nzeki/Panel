import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../widgets/bar_chart.dart';
import '../widgets/common.dart';
import '../widgets/updates_button.dart';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final counts = ref.watch(statusCountsProvider);
    final daily = ref.watch(chaptersPerDayProvider);
    final monthly = ref.watch(completionsPerMonthProvider);
    final c = context.colors;
    final sc = context.statusColors;

    // Every title's chapters, earlier read-throughs included: deleting a
    // title or lowering its chapter takes them off; a reread keeps them.
    final chapters = entries.fold<int>(0, (a, e) => a + e.chaptersCounted);
    final rereads = entries.fold<int>(0, (a, e) => a + e.reread);
    final byType = {for (final t in EntryType.values) t: 0};
    for (final e in entries) {
      byType[e.type] = byType[e.type]! + 1;
    }

    Future<void> refresh() async {
      ref.invalidate(chaptersPerDayProvider);
      ref.invalidate(completionsPerMonthProvider);
      await ref.read(entriesProvider.notifier).refresh();
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
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
                  Text('Your reading',
                      style: context.text.labelLarge
                          ?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text('Stats', style: context.text.headlineSmall),
                ],
              ),
              actions: const [UpdatesButton(), SizedBox(width: 8)],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList.list(children: [
                // ---- Headline numbers ----
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.9,
                  children: [
                    _StatTile(
                        label: 'Titles tracked',
                        value: entries.length,
                        icon: Icons.collections_bookmark_rounded,
                        color: c.primary),
                    _StatTile(
                        label: 'Chapters read',
                        value: chapters,
                        icon: Icons.menu_book_rounded,
                        color: sc.of(EntryStatus.reading)),
                    _StatTile(
                        label: 'Finished',
                        value: counts[EntryStatus.finished] ?? 0,
                        icon: Icons.task_alt_rounded,
                        color: sc.of(EntryStatus.finished)),
                    _StatTile(
                        label: 'Rereads',
                        value: rereads,
                        icon: Icons.replay_rounded,
                        color: sc.of(EntryStatus.toRead)),
                  ],
                ),

                // ---- Last 14 days ----
                const SectionLabel('Last 14 days'),
                _Panel(
                  child: daily.when(
                    loading: () => const SizedBox(
                        height: 220,
                        child: Center(child: CircularProgressIndicator())),
                    error: (e, _) => _PanelError(
                        message: friendlyError(e),
                        onRetry: () => ref.invalidate(chaptersPerDayProvider)),
                    data: (days) {
                      final total = days.fold<int>(0, (a, d) => a + d.chapters);
                      final avg = days.isEmpty ? 0.0 : total / days.length;
                      var streak = 0;
                      for (var i = days.length - 1; i >= 0; i--) {
                        if (days[i].chapters > 0) {
                          streak++;
                        } else if (i != days.length - 1) {
                          break; // today can still be 0 without breaking it
                        }
                      }
                      final fmt = DateFormat.Md();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            _Metric(value: '$total', label: 'chapters'),
                            _Metric(
                                value: avg.toStringAsFixed(1),
                                label: 'per day'),
                            _Metric(
                                value: '$streak',
                                label: 'day streak',
                                icon: Icons.local_fire_department_rounded),
                          ]),
                          const SizedBox(height: 8),
                          SimpleBarChart(
                            labelEvery: 3,
                            unit: ' ch',
                            data: [
                              for (var i = 0; i < days.length; i++)
                                BarDatum(
                                  i == days.length - 1
                                      ? 'Today'
                                      : fmt.format(days[i].day),
                                  days[i].chapters,
                                  highlight: i == days.length - 1,
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // ---- Finished per month ----
                const SectionLabel('Finished per month'),
                _Panel(
                  child: monthly.when(
                    loading: () => const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator())),
                    error: (e, _) => _PanelError(
                        message: friendlyError(e),
                        onRetry: () =>
                            ref.invalidate(completionsPerMonthProvider)),
                    data: (months) {
                      final fmt = DateFormat.MMM();
                      final thisMonth = months.isEmpty ? 0 : months.last.count;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            _Metric(value: '$thisMonth', label: 'this month'),
                            _Metric(
                                value:
                                    '${months.fold<int>(0, (a, m) => a + m.count)}',
                                label: 'in 6 months'),
                          ]),
                          const SizedBox(height: 8),
                          SimpleBarChart(
                            height: 120,
                            color: sc.of(EntryStatus.finished),
                            data: [
                              for (var i = 0; i < months.length; i++)
                                BarDatum(fmt.format(months[i].month),
                                    months[i].count,
                                    highlight: i == months.length - 1),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // ---- Status breakdown ----
                const SectionLabel('By status'),
                _Panel(
                  child: StackedBar(segments: [
                    for (final s in EntryStatus.values)
                      (label: s.label, value: counts[s] ?? 0, color: sc.of(s)),
                  ]),
                ),

                // ---- Type breakdown ----
                const SectionLabel('By type'),
                _Panel(
                  child: Column(children: [
                    for (final t in EntryType.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          SizedBox(
                              width: 72,
                              child: Text(t.label,
                                  style: context.text.labelLarge)),
                          Expanded(
                            child: ThinProgress(
                              value: entries.isEmpty
                                  ? 0.0
                                  : byType[t]! / entries.length,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text('${byType[t]}',
                                textAlign: TextAlign.right,
                                style: context.text.labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w800)),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );
}

class _PanelError extends StatelessWidget {
  const _PanelError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 140,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(message, textAlign: TextAlign.center),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label, this.icon});
  final String value;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(value, style: context.text.titleLarge),
              if (icon != null) ...[
                const SizedBox(width: 4),
                Icon(icon, size: 18, color: const Color(0xFFF97316)),
              ],
            ]),
            Text(label,
                style: context.text.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant)),
          ],
        ),
      );
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final int value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: value.toDouble()),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => Text(
                      NumberFormat.decimalPattern().format(v.round()),
                      style: context.text.headlineSmall,
                    ),
                  ),
                ),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
