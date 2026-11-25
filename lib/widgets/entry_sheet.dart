import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/entry.dart';
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
