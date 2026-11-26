import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entry.dart';
import '../services/mangadex.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/dates.dart';
import 'common.dart';
import 'entry_card.dart';

Future<void> showEntrySheet(BuildContext context, String entryId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) =>
          _EntrySheet(entryId: entryId, controller: controller),
    ),
  );
}

class _EntrySheet extends ConsumerWidget {
  const _EntrySheet({required this.entryId, required this.controller});

  final String entryId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(entriesProvider).value ?? const <Entry>[];
    final matches = list.where((e) => e.id == entryId);
    if (matches.isEmpty) {
      return const SizedBox(height: 200);
    }
    final e = matches.first;
    final c = context.colors;
    final notifier = ref.read(entriesProvider.notifier);

    Future<void> run(Future<void> Function() op) async {
      try {
        await op();
      } catch (err) {
        if (context.mounted) showSnack(context, friendlyError(err), error: true);
      }
    }

    return ListView(
      controller: controller,
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        // ---- Header ----
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(url: e.coverUrl, title: e.title, width: 96, height: 136),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => run(() async {
                      final t = await promptText(context,
                          title: 'Rename title', initial: e.title);
                      if (t == null || t.trim().isEmpty || t.trim() == e.title) {
                        return;
                      }
                      await notifier.save(
                          e, e.copyWith(title: t.trim()), {'title': t.trim()});
                    }),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: e.title),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(Icons.edit_rounded,
                                size: 16, color: c.onSurfaceVariant),
                          ),
                        ),
                      ]),
                      style: context.text.titleLarge?.copyWith(height: 1.2),
                    ),
                  ),
                  if (e.author != null && e.author!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(e.author!,
                        style: context.text.bodyMedium
                            ?.copyWith(color: c.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    StatusBadge(e.status),
                    TagChip(e.type.label),
                  ]),
                  const SizedBox(height: 10),
                  if (e.createdAt != null)
                    Text(
                      'Added ${relativeTime(e.createdAt!)}'
                      '${e.lastReadAt != null ? ' · read ${relativeTime(e.lastReadAt!)}' : ''}',
                      style: context.text.labelSmall
                          ?.copyWith(color: c.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),

        // ---- Chapter stepper ----
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  _RoundIconButton(
                    icon: Icons.remove_rounded,
                    onTap: e.chapter > 0
                        ? () => run(() => notifier.bumpChapter(e, -1))
                        : null,
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => run(() async {
                        final v = await promptNumber(context,
                            title: 'Current chapter', initial: e.chapter);
                        if (v == null || v == e.chapter) return;
                        await notifier.bumpChapter(e, (v - e.chapter).toInt());
                      }),
                      child: Column(
                        children: [
                          Text('CHAPTER',
                              style: context.text.labelSmall?.copyWith(
                                  color: c.onSurfaceVariant,
                                  letterSpacing: 1.2)),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) => ScaleTransition(
                                scale: anim, child: child),
                            child: Text(
                              '${e.chapter}',
                              key: ValueKey(e.chapter),
                              style: context.text.displaySmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                          Text(
                            e.totalChapters != null
                                ? 'of ${e.totalChapters}'
                                : 'tap to set',
                            style: context.text.labelMedium
                                ?.copyWith(color: c.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _RoundIconButton(
                    icon: Icons.add_rounded,
                    filled: true,
                    onTap: () => run(() => notifier.bumpChapter(e, 1)),
                  ),
                ],
              ),
              if (e.progress != null) ...[
                const SizedBox(height: 14),
                ThinProgress(
                    value: e.progress, color: context.statusColors.of(e.status)),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => run(() => notifier.bumpChapter(e, 5)),
                    icon: const Icon(Icons.fast_forward_rounded, size: 18),
                    label: const Text('+5'),
                  ),
                  TextButton.icon(
                    onPressed: () => run(() async {
                      final v = await promptNumber(context,
                          title: 'Total chapters',
                          initial: e.totalChapters,
                          allowEmpty: true);
                      if (v == e.totalChapters) return;
                      await notifier.save(
                        e,
                        e.copyWith(totalChapters: Nullable(v)),
                        {'total_chapters': v},
                      );
                    }),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Set total'),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ---- Status ----
        const SectionLabel('Status'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in EntryStatus.values)
              _StatusChoice(
                status: s,
                selected: s == e.status,
                onTap: () => run(() => notifier.setStatus(e, s)),
              ),
          ],
        ),

        // ---- Type ----
        const SectionLabel('Type'),
        SegmentedButton<EntryType>(
          showSelectedIcon: false,
          segments: [
            for (final t in EntryType.values)
              ButtonSegment(value: t, label: Text(t.label)),
          ],
          selected: {e.type},
          onSelectionChanged: (sel) => run(() => notifier.save(
              e, e.copyWith(type: sel.first), {'type': sel.first.label})),
        ),

        // ---- Rereads ----
        const SectionLabel('Rereads'),
        Row(
          children: [
            _RoundIconButton(
              icon: Icons.remove_rounded,
              small: true,
              onTap: e.reread > 0
                  ? () => run(() => notifier.save(e,
                      e.copyWith(reread: e.reread - 1), {'reread': e.reread - 1}))
                  : null,
            ),
            SizedBox(
              width: 56,
              child: Text('${e.reread}',
                  textAlign: TextAlign.center,
                  style: context.text.titleLarge),
            ),
            _RoundIconButton(
              icon: Icons.add_rounded,
              small: true,
              onTap: () => run(() => notifier.save(e,
                  e.copyWith(reread: e.reread + 1), {'reread': e.reread + 1})),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Each reread counts as another finish in your stats.',
                style: context.text.bodySmall
                    ?.copyWith(color: c.onSurfaceVariant),
              ),
            ),
          ],
        ),

        // ---- Source (covers + new chapters) ----
        if (e.type != EntryType.comic) ...[
          const SectionLabel('New chapters'),
          _SourceRow(entry: e, run: run),
        ],

        // ---- Read on ----
        const SectionLabel('Where you read it'),
        _ReadOnRow(entry: e, run: run),

        // ---- Danger ----
        const SizedBox(height: 28),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: c.error,
            side: BorderSide(color: c.error.withValues(alpha: 0.4)),
          ),
          onPressed: () async {
            final ok = await confirm(context,
                title: 'Delete “${e.title}”?',
                message: 'You can undo right after.',
                action: 'Delete',
                destructive: true);
            if (ok != true || !context.mounted) return;
            Navigator.of(context).pop();
            await deleteWithUndo(context, ref, e);
          },
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Delete from list'),
        ),
      ],
    );
  }
}

class _ReadOnRow extends StatelessWidget {
  const _ReadOnRow({required this.entry, required this.run});
  final Entry entry;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final url = entry.readOnUrl;
    final c = context.colors;
    return Consumer(builder: (context, ref, _) {
      final notifier = ref.read(entriesProvider.notifier);
      Future<void> edit() => run(() async {
            final v = await promptText(context,
                title: 'Where do you read this?',
                hint: 'https://…',
                initial: url ?? '',
                keyboard: TextInputType.url);
            if (v == null) return;
            var next = v.trim();
            if (next.isNotEmpty && !next.contains('://')) next = 'https://$next';
            final value = next.isEmpty ? null : next;
            if (value == url) return;
            await notifier.save(entry, entry.copyWith(readOnUrl: Nullable(value)),
                {'read_on_url': value});
          });

      if (url == null || url.isEmpty) {
        return OutlinedButton.icon(
          onPressed: edit,
          icon: const Icon(Icons.add_link_rounded),
          label: const Text('Add a reading link'),
        );
      }
      final host = Uri.tryParse(url)?.host ?? url;
      return Card(
        child: ListTile(
          leading: Icon(Icons.link_rounded, color: c.primary),
          title: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Tap to open'),
          onTap: () => launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication),
          trailing: IconButton(
            tooltip: 'Edit link',
            icon: const Icon(Icons.edit_outlined),
            onPressed: edit,
          ),
        ),
      );
    });
  }
}

class _SourceRow extends ConsumerWidget {
  const _SourceRow({required this.entry, required this.run});
  final Entry entry;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final notifier = ref.read(entriesProvider.notifier);
    Future<void> pick() => run(() async {
          final m = await showSourcePicker(context, entry.title);
          if (m == null) return;
          await notifier.linkSource(entry, m);
          if (context.mounted) showSnack(context, 'Linked to “${m.title}”');
        });

    if (!entry.isLinked) {
      return OutlinedButton.icon(
        onPressed: pick,
        icon: const Icon(Icons.travel_explore_rounded),
        label: Text(entry.sourceId == noSourceFound
            ? 'No match found — pick the series'
            : 'Find series (cover + new chapters)'),
      );
    }

    final latest = entry.latestChapter;
    final checked = entry.latestCheckedAt;
    final unread = entry.unreadChapters;
    return Card(
      child: ListTile(
        leading: Icon(
          unread > 0 ? Icons.fiber_new_rounded : Icons.notifications_active_outlined,
          color: unread > 0 ? c.tertiary : c.primary,
        ),
        title: Text(latest == null
            ? 'MangaDex · no English chapters yet'
            : unread > 0
                ? 'Chapter $latest is out · $unread new'
                : 'Up to date · latest is Ch $latest'),
        subtitle: Text(checked == null
            ? 'Checked every 5 hours'
            : 'Checked ${relativeTime(checked)} · every 5 hours'),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => switch (v) {
            'refresh' => run(() => notifier.refreshLatest(entry)),
            'change' => pick(),
            _ => run(() => notifier.unlinkSource(entry)),
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'refresh', child: Text('Check now')),
            PopupMenuItem(value: 'change', child: Text('Change series / cover')),
            PopupMenuItem(value: 'unlink', child: Text('Stop checking')),
          ],
        ),
      ),
    );
  }
}

/// Lets the reader pick the right series on MangaDex (with covers, so the
/// correct one is easy to spot). Returns null if cancelled.
Future<SourceManga?> showSourcePicker(BuildContext context, String title) {
  return showModalBottomSheet<SourceManga>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) =>
          _SourcePicker(initial: title, controller: controller),
    ),
  );
}

class _SourcePicker extends ConsumerStatefulWidget {
  const _SourcePicker({required this.initial, required this.controller});
  final String initial;
  final ScrollController controller;

  @override
  ConsumerState<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends ConsumerState<_SourcePicker> {
  late final _query = TextEditingController(text: widget.initial);
  Future<List<SourceManga>>? _results;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() => setState(() {
        _results = ref.read(mangaDexProvider).search(_query.text, limit: 20);
      });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search MangaDex',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: _search,
              ),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<SourceManga>>(
            future: _results,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text(friendlyError(snap.error!)));
              }
              final list = snap.data ?? const [];
              if (list.isEmpty) {
                return const Center(child: Text('No series found. Try another name.'));
              }
              return ListView.builder(
                controller: widget.controller,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(m),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            CoverImage(
                                url: m.coverUrl, title: m.title, width: 56, height: 80),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.text.titleSmall),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (m.status != null) m.status!,
                                      if (m.year != null) '${m.year}',
                                    ].join(' · '),
                                    style: context.text.labelSmall
                                        ?.copyWith(color: c.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _StatusChoice extends StatelessWidget {
  const _StatusChoice(
      {required this.status, required this.selected, required this.onTap});

  final EntryStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = context.statusColors.of(status);
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.16) : c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? color : c.outlineVariant,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(status.label,
                style: context.text.labelLarge?.copyWith(
                    color: selected ? color : c.onSurface)),
          ]),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.small = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = small ? 40.0 : 56.0;
    return Material(
      color: filled ? c.primary : c.surfaceContainerHigh,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: small ? 20 : 28,
            color: onTap == null
                ? c.onSurface.withValues(alpha: 0.3)
                : filled
                    ? c.onPrimary
                    : c.onSurface,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small dialogs used around the app
// ---------------------------------------------------------------------------

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  TextInputType keyboard = TextInputType.text,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: keyboard,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save')),
      ],
    ),
  );
}

/// Returns the entered number, or null if cancelled. With [allowEmpty], an
/// empty field also returns null (meaning "clear it") — callers compare
/// against the old value.
Future<int?> promptNumber(
  BuildContext context, {
  required String title,
  int? initial,
  bool allowEmpty = false,
}) async {
  final controller = TextEditingController(text: initial?.toString() ?? '');
  final result = await showDialog<({int? value})>(
    context: context,
    builder: (ctx) {
      void submit() {
        final t = controller.text.trim();
        if (t.isEmpty) {
          if (allowEmpty) Navigator.pop(ctx, (value: null));
          return;
        }
        final v = int.tryParse(t);
        if (v != null && v >= 0) Navigator.pop(ctx, (value: v));
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
              hintText: allowEmpty ? 'Leave empty if unknown' : null),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    },
  );
  if (result == null) return initial; // cancelled → unchanged
  return result.value;
}

Future<bool?> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String action = 'OK',
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message != null ? Text(message) : null,
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
}
