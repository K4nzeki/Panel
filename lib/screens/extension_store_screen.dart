import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/extension_repo.dart';
import '../state/extensions.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/entry_sheet.dart' show confirm;

/// Browse extension repos (like Keiyoushi's) and install extensions.
/// Installed extensions are also where Panel looks for covers it can't
/// find on AniList or MangaDex.
class ExtensionStoreScreen extends ConsumerStatefulWidget {
  const ExtensionStoreScreen({super.key});

  @override
  ConsumerState<ExtensionStoreScreen> createState() =>
      _ExtensionStoreScreenState();
}

class _ExtensionStoreScreenState extends ConsumerState<ExtensionStoreScreen> {
  final _search = TextEditingController();
  bool _installedOnly = false;
  bool _showNsfw = false;
  String? _lang; // null = every language

  @override
  void initState() {
    super.initState();
    // Fresh "installed" state every time the store opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(extensionStoreProvider.notifier).refreshInstalled();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(extensionStoreProvider);
    final notifier = ref.read(extensionStoreProvider.notifier);
    final c = context.colors;

    final all = store.extensions;
    final langs = {for (final e in all) e.lang}.toList()
      ..sort((a, b) => langName(a).compareTo(langName(b)));
    // Default to English when the repo has it.
    final lang = _lang ?? (langs.contains('en') ? 'en' : null);
    final q = _search.text.trim().toLowerCase();
    final shown = all.where((e) {
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
      if (_installedOnly) return store.isInstalled(e);
      if (!_showNsfw && e.isNsfw) return false;
      if (lang != null && lang != '*' && e.lang != lang && e.lang != 'all') {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        // Updates first, then installed, then A–Z.
        int rank(Extension e) =>
            store.hasUpdate(e) ? 0 : (store.isInstalled(e) ? 1 : 2);
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final installedCount = all.where(store.isInstalled).length;
    final updates = all.where(store.hasUpdate).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Extension store'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: store.loading ? null : notifier.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Repos',
            onPressed: () => _showRepos(context),
            icon: const Icon(Icons.source_outlined),
          ),
        ],
        bottom: store.loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      floatingActionButton: store.repoUrls.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showAddRepoDialog(context, ref),
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Add repo'),
            ),
      body: store.repoUrls.isEmpty
          ? EmptyState(
              icon: Icons.extension_outlined,
              title: 'Add an extension repo',
              message: 'Paste a repo link (for example Keiyoushi) to browse '
                  'and install extensions. Panel can read chapters from the '
                  'sites of installed extensions and uses them to find '
                  'missing covers.',
              action: FilledButton.icon(
                onPressed: () => showAddRepoDialog(context, ref),
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Add repo'),
              ),
            )
          : CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in store.repoErrors.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: c.errorContainer,
                            borderRadius: BorderRadius.circular(14),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '${store.repos[entry.key]?.name ?? entry.key}: '
                                '${entry.value}'
                                '${(store.repos[entry.key]?.extensions.isNotEmpty ?? false) ? ' Showing the copy saved on this phone.' : ''}',
                                style: context.text.bodySmall
                                    ?.copyWith(color: c.onErrorContainer),
                              ),
                            ),
                          ),
                        ),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                              value: false,
                              label: Text('Browse (${all.length})')),
                          ButtonSegment(
                              value: true,
                              label: Text(updates > 0
                                  ? 'Installed ($installedCount · $updates update${updates == 1 ? '' : 's'})'
                                  : 'Installed ($installedCount)')),
                        ],
                        selected: {_installedOnly},
                        onSelectionChanged: (s) =>
                            setState(() => _installedOnly = s.first),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search extensions',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () =>
                                      setState(() => _search.clear()),
                                ),
                        ),
                      ),
                      if (!_installedOnly) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          PopupMenuButton<String>(
                            initialValue: lang ?? '*',
                            onSelected: (v) => setState(() => _lang = v),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: '*', child: Text('All languages')),
                              for (final l in langs)
                                PopupMenuItem(value: l, child: Text(langName(l))),
                            ],
                            child: Chip(
                              avatar: const Icon(Icons.translate_rounded,
                                  size: 18),
                              label: Text(lang == null || lang == '*'
                                  ? 'All languages'
                                  : langName(lang)),
                            ),
                          ),
                          FilterChip(
                            label: const Text('Show 18+'),
                            selected: _showNsfw,
                            onSelected: (v) => setState(() => _showNsfw = v),
                          ),
                        ]),
                      ],
                      if (_installedOnly && installedCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Panel reads chapters from these sites directly '
                            '(pick one as a title\'s source) and searches them '
                            'for missing covers. Sites using the Madara or '
                            'MangaThemesia themes work; others need a reader '
                            'app like Mihon.',
                            style: context.text.bodySmall
                                ?.copyWith(color: c.onSurfaceVariant),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              if (shown.isEmpty && !store.loading)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: _installedOnly
                        ? Icons.extension_off_outlined
                        : Icons.search_off_rounded,
                    title: _installedOnly
                        ? 'No extensions installed'
                        : 'Nothing matches',
                    message: _installedOnly
                        ? 'Install one from Browse.'
                        : 'Try another name or language.',
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
                  sliver: SliverList.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) => _ExtensionTile(ext: shown[i]),
                  ),
                ),
            ]),
    );
  }

  void _showRepos(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _ReposSheet(),
    );
  }
}

class _ExtensionTile extends ConsumerWidget {
  const _ExtensionTile({required this.ext});
  final Extension ext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(extensionStoreProvider);
    final notifier = ref.read(extensionStoreProvider.notifier);
    final c = context.colors;
    final installed = store.isInstalled(ext);
    final update = store.hasUpdate(ext);
    final downloading = store.downloading.containsKey(ext.pkg);
    final progress = store.downloading[ext.pkg];

    Future<void> install() async {
      try {
        final ok = await notifier.install(ext);
        if (!ok && context.mounted) {
          showSnack(context,
              'Allow Panel to install apps, then tap ${update ? 'Update' : 'Install'} again.');
        }
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString(), error: true);
      }
    }

    final details = [
      'v${ext.versionName}',
      langName(ext.lang),
      if (ext.sources.length > 1) '${ext.sources.length} sources',
      if (ext.isNsfw) '18+',
    ].join(' · ');

    final Widget trailing;
    if (downloading) {
      trailing = SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(value: progress, strokeWidth: 3),
      );
    } else if (update) {
      trailing = FilledButton.tonal(
          onPressed: ExtensionStoreNotifier.supported ? install : null,
          child: const Text('Update'));
    } else if (installed) {
      trailing = IconButton(
        tooltip: 'Uninstall',
        onPressed: () => notifier.uninstall(ext.pkg),
        icon: Icon(Icons.delete_outline_rounded, color: c.onSurfaceVariant),
      );
    } else {
      trailing = OutlinedButton(
          onPressed: ExtensionStoreNotifier.supported ? install : null,
          child: const Text('Install'));
    }

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 42,
          height: 42,
          child: ext.iconUrl == null
              ? _fallbackIcon(c)
              : Image.network(ext.iconUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _fallbackIcon(c)),
        ),
      ),
      title: Text(ext.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        installed && !update ? 'Installed · $details' : details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
      onTap: () => _showDetails(context, ext),
    );
  }

  static Widget _fallbackIcon(ColorScheme c) => ColoredBox(
        color: c.surfaceContainerHighest,
        child: Icon(Icons.extension_rounded, color: c.onSurfaceVariant),
      );

  void _showDetails(BuildContext context, Extension e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(e.name, style: context.text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'v${e.versionName} · ${e.pkg}',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SectionLabel('Sites'),
            for (final s in e.sources)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('${s.name} (${langName(s.lang)})'),
                subtitle: Text(s.baseUrl),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReposSheet extends ConsumerWidget {
  const _ReposSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(extensionStoreProvider);
    final notifier = ref.read(extensionStoreProvider.notifier);
    final c = context.colors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Repos', style: context.text.titleLarge),
            ),
            for (final url in store.repoUrls)
              ListTile(
                leading: const Icon(Icons.source_outlined),
                title: Text(store.repos[url]?.name ?? url),
                subtitle: Text(
                  store.repoErrors[url] != null
                      ? "Couldn't load · $url"
                      : '${store.repos[url]?.extensions.length ?? 0} extensions · $url',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Remove repo',
                  icon: Icon(Icons.delete_outline_rounded, color: c.error),
                  onPressed: () async {
                    final ok = await confirm(context,
                        title: 'Remove this repo?',
                        message: 'Extensions you installed stay on your phone.',
                        action: 'Remove',
                        destructive: true);
                    if (ok == true) await notifier.removeRepo(url);
                  },
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.tonalIcon(
                onPressed: () => showAddRepoDialog(context, ref),
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Add repo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a repo link, checks it loads, and adds it.
Future<void> showAddRepoDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _AddRepoDialog(),
  );
}

class _AddRepoDialog extends ConsumerStatefulWidget {
  const _AddRepoDialog();

  @override
  ConsumerState<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends ConsumerState<_AddRepoDialog> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo =
          await ref.read(extensionStoreProvider.notifier).addRepo(_url.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context,
          'Added ${repo.name} · ${repo.extensions.length} extensions');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      title: const Text('Add extension repo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Repo link',
              hintText: 'https://…/index.pb',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _busy
                    ? null
                    : () async {
                        final d = await Clipboard.getData(Clipboard.kTextPlain);
                        if (d?.text != null) _url.text = d!.text!.trim();
                      },
              ),
            ),
            onSubmitted: (_) => _busy ? null : _add(),
          ),
          const SizedBox(height: 10),
          ActionChip(
            avatar: const Icon(Icons.bolt_rounded, size: 18),
            label: const Text('Use the Keiyoushi repo'),
            onPressed: _busy ? null : () => _url.text = keiyoushiRepoUrl,
          ),
          const SizedBox(height: 10),
          Text(
            'Extensions are apps made by other people. Only add repos you trust.',
            style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _add,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// "en" -> "English". Unknown codes are shown as-is.
String langName(String code) => switch (code) {
      'all' => 'Multi',
      'en' => 'English',
      'es' => 'Spanish',
      'es-419' => 'Spanish (Latin America)',
      'pt' => 'Portuguese',
      'pt-BR' => 'Portuguese (Brazil)',
      'fr' => 'French',
      'de' => 'German',
      'it' => 'Italian',
      'ru' => 'Russian',
      'uk' => 'Ukrainian',
      'pl' => 'Polish',
      'tr' => 'Turkish',
      'ar' => 'Arabic',
      'id' => 'Indonesian',
      'fil' => 'Filipino',
      'vi' => 'Vietnamese',
      'th' => 'Thai',
      'ja' => 'Japanese',
      'ko' => 'Korean',
      'zh' => 'Chinese',
      'zh-Hans' => 'Chinese (Simplified)',
      'zh-Hant' => 'Chinese (Traditional)',
      'ms' => 'Malay',
      'my' => 'Burmese',
      'hi' => 'Hindi',
      'bn' => 'Bengali',
      'fa' => 'Persian',
      'he' => 'Hebrew',
      'el' => 'Greek',
      'cs' => 'Czech',
      'hu' => 'Hungarian',
      'ro' => 'Romanian',
      'bg' => 'Bulgarian',
      'ca' => 'Catalan',
      'nl' => 'Dutch',
      'sv' => 'Swedish',
      _ => code,
    };
