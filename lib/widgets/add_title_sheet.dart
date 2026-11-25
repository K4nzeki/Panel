import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'common.dart';

Future<void> showAddTitleSheet(BuildContext context,
    {EntryStatus status = EntryStatus.reading}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) =>
          _AddTitleSheet(initialStatus: status, controller: controller),
    ),
  );
}

/// Adds an AniList result to the list. Returns true if added.
Future<bool> addResult(BuildContext context, WidgetRef ref, SearchResult r,
    EntryStatus status) async {
  final notifier = ref.read(entriesProvider.notifier);
  final existing = notifier.findByTitle(r.title);
  if (existing != null) {
    showSnack(context, '“${r.title}” is already in your list');
    return false;
  }
  try {
    await notifier.add(
      title: r.title,
      type: r.type,
      status: status,
      coverUrl: r.coverUrl,
      author: r.author,
      totalChapters: r.totalChapters,
    );
    unawaited(HapticFeedback.lightImpact());
    if (context.mounted) {
      showSnack(context,
          'Added “${r.title}” to ${status == EntryStatus.toRead ? 'To Read' : 'your library'}');
    }
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return false;
  }
}

class _AddTitleSheet extends ConsumerStatefulWidget {
  const _AddTitleSheet({required this.initialStatus, required this.controller});
  final EntryStatus initialStatus;
  final ScrollController controller;

  @override
  ConsumerState<_AddTitleSheet> createState() => _AddTitleSheetState();
}

class _AddTitleSheetState extends ConsumerState<_AddTitleSheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  late EntryStatus _status = widget.initialStatus == EntryStatus.toRead
      ? EntryStatus.toRead
      : EntryStatus.reading;

  List<SearchResult> _results = const [];
  bool _loading = false;
  String? _error;
  int _requestId = 0;
  final Set<String> _added = {};
  bool _manual = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(q));
  }

  Future<void> _run(String q) async {
    final id = ++_requestId;
    if (q.trim().length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(aniListProvider).search(q);
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = r;
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add a title', style: context.text.headlineSmall),
              const SizedBox(height: 14),
              SegmentedButton<EntryStatus>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: EntryStatus.reading,
                    icon: Icon(Icons.auto_stories_rounded),
                    label: Text('Reading now'),
                  ),
                  ButtonSegment(
                    value: EntryStatus.toRead,
                    icon: Icon(Icons.bookmark_add_outlined),
                    label: Text('To Read'),
                  ),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
              const SizedBox(height: 12),
              if (!_manual)
                TextField(
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: _run,
                  decoration: InputDecoration(
                    hintText: 'Search AniList by title…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _search.clear();
                              _onChanged('');
                            },
                          ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _manual
              ? _ManualForm(
                  controller: widget.controller,
                  status: _status,
                  initialTitle: _search.text.trim(),
                  onCancel: () => setState(() => _manual = false),
                )
              : ListView(
                  controller: widget.controller,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_error != null)
                      EmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: "Couldn't search",
                        message: _error!,
                        action: OutlinedButton(
                            onPressed: () => _run(_search.text),
                            child: const Text('Try again')),
                      )
                    else if (_results.isEmpty && _search.text.trim().length >= 2)
                      const EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No matches on AniList',
                        message:
                            'Western comics and very new titles often aren\'t listed. Add it manually below.',
                      )
                    else if (_results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'Type a title to find its cover, author and chapter count automatically.',
                          textAlign: TextAlign.center,
                          style: context.text.bodyMedium
                              ?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ),
                    for (final r in _results)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ResultTile(
                          result: r,
                          added: _added.contains(r.id) ||
                              inList.contains(r.title.trim().toLowerCase()),
                          onAdd: () async {
                            final ok = await addResult(context, ref, r, _status);
                            if (ok && mounted) setState(() => _added.add(r.id));
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _manual = true),
                      icon: const Icon(Icons.edit_note_rounded),
                      label: const Text('Add manually instead'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A search result row with cover, metadata and an Add button.
class ResultTile extends StatelessWidget {
  const ResultTile({
    super.key,
    required this.result,
    required this.added,
    required this.onAdd,
    this.onTap,
  });

  final SearchResult result;
  final bool added;
  final VoidCallback onAdd;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = result;
    final meta = [
      r.type.label,
      if (r.totalChapters != null) '${r.totalChapters} ch',
      if (r.publicationStatus != null) r.publicationStatus!,
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              CoverImage(url: r.coverUrl, title: r.title, width: 50, height: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleSmall),
                    if (r.author != null) ...[
                      const SizedBox(height: 2),
                      Text(r.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall
                              ?.copyWith(color: c.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 4),
                    Text(meta,
                        style: context.text.labelSmall
                            ?.copyWith(color: c.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              added
                  ? Icon(Icons.check_circle_rounded, color: c.primary)
                  : IconButton.filledTonal(
                      tooltip: 'Add',
                      onPressed: onAdd,
                      icon: const Icon(Icons.add_rounded),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManualForm extends ConsumerStatefulWidget {
  const _ManualForm({
    required this.controller,
    required this.status,
    required this.initialTitle,
    required this.onCancel,
  });

  final ScrollController controller;
  final EntryStatus status;
  final String initialTitle;
  final VoidCallback onCancel;

  @override
  ConsumerState<_ManualForm> createState() => _ManualFormState();
}

class _ManualFormState extends ConsumerState<_ManualForm> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.initialTitle);
  final _author = TextEditingController();
  final _chapter = TextEditingController();
  final _total = TextEditingController();
  final _link = TextEditingController();
  EntryType _type = EntryType.manga;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_title, _author, _chapter, _total, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final notifier = ref.read(entriesProvider.notifier);
    final title = _title.text.trim();
    if (notifier.findByTitle(title) != null) {
      showSnack(context, '“$title” is already in your list');
      return;
    }
    var link = _link.text.trim();
    if (link.isNotEmpty && !link.contains('://')) link = 'https://$link';
    setState(() => _saving = true);
    try {
      await notifier.add(
        title: title,
        type: _type,
        status: widget.status,
        chapter: int.tryParse(_chapter.text.trim()) ?? 0,
        totalChapters: int.tryParse(_total.text.trim()),
        author: _author.text.trim().isEmpty ? null : _author.text.trim(),
        readOnUrl: link.isEmpty ? null : link,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context, 'Added “$title”');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Form(
      key: _form,
      child: ListView(
        controller: widget.controller,
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
        children: [
          TextFormField(
            controller: _title,
            autofocus: widget.initialTitle.isEmpty,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Title'),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Give it a title' : null,
          ),
          gap,
          TextFormField(
            controller: _author,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Author (optional)'),
          ),
          gap,
          SegmentedButton<EntryType>(
            showSelectedIcon: false,
            segments: [
              for (final t in EntryType.values)
                ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          gap,
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _chapter,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: const InputDecoration(labelText: 'Current chapter'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _total,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: const InputDecoration(labelText: 'Total (optional)'),
              ),
            ),
          ]),
          gap,
          TextFormField(
            controller: _link,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Where you read it (optional)',
              hintText: 'https://…',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Add to list'),
          ),
          const SizedBox(height: 8),
          TextButton(
              onPressed: widget.onCancel,
              child: const Text('Back to search')),
        ],
      ),
    );
  }
}
