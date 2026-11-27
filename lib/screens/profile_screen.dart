import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/entry.dart';
import '../services/downloads.dart';
import '../services/sheet_file.dart';
import '../state/downloads.dart';
import '../state/extensions.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/import_merge.dart';
import '../utils/import_parser.dart';
import '../utils/sheet_import.dart';
import '../widgets/common.dart';
import '../widgets/entry_sheet.dart';
import '../widgets/update_dialog.dart';
import 'extension_store_screen.dart';
import 'legal_screen.dart';

/// Settings tab. Panel has no accounts: everything here is saved on this
/// phone only.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final c = context.colors;
    final downloads = ref.watch(downloadsProvider);
    final size = ref.watch(downloadsSizeProvider).value;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            toolbarHeight: 72,
            titleSpacing: 20,
            title: Text('Settings'),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            sliver: SliverList.list(children: [
              Card(
                child: ListTile(
                  leading: Icon(Icons.phone_android_rounded, color: c.primary),
                  title: const Text('Saved on this phone'),
                  subtitle: const Text(
                      'No account or password. Your list, progress and '
                      'downloads stay on this device and work offline.'),
                ),
              ),

              // ---- Appearance ----
              const SectionLabel('Appearance'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: ThemeMode.system,
                          icon: Icon(Icons.brightness_auto_rounded),
                          label: Text('System')),
                      ButtonSegment(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_rounded),
                          label: Text('Light')),
                      ButtonSegment(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_rounded),
                          label: Text('Dark')),
                    ],
                    selected: {themeMode},
                    onSelectionChanged: (s) =>
                        ref.read(themeModeProvider.notifier).set(s.first),
                  ),
                ),
              ),

              // ---- Extensions ----
              const SectionLabel('Sources & extensions'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('Extension store'),
                  subtitle: Text(switch (ref.watch(extensionStoreProvider)) {
                    final s when s.repoUrls.isEmpty =>
                      'Add a repo to read from more sites (MangaDex is built in)',
                    final s =>
                      '${s.extensions.where(s.isInstalled).length} installed · '
                          '${s.repoUrls.length} repo${s.repoUrls.length == 1 ? '' : 's'}',
                  }),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ExtensionStoreScreen())),
                ),
              ),

              // ---- Downloads ----
              if (DownloadStore.supported) ...[
                const SectionLabel('Downloads'),
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text('${downloads.done.length} chapters downloaded'),
                      subtitle: FutureBuilder<String>(
                        future: _folderLabel(),
                        builder: (_, snap) => Text([
                          if (size != null) _bytes(size),
                          snap.data ?? '…',
                        ].join(' · ')),
                      ),
                    ),
                    if (downloads.queue.isNotEmpty) ...[
                      const Divider(indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(Icons.downloading_rounded),
                        title: Text('${downloads.queue.length} in the queue'),
                        subtitle: Text(downloads.waitingForConnection
                            ? 'Paused until you are back online'
                            : 'Downloading one chapter at a time'),
                        trailing: TextButton(
                          onPressed: downloads.waitingForConnection
                              ? ref.read(downloadsProvider.notifier).resume
                              : ref.read(downloadsProvider.notifier).cancelAll,
                          child: Text(downloads.waitingForConnection
                              ? 'Retry'
                              : 'Cancel all'),
                        ),
                      ),
                    ],
                    const Divider(indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(Icons.delete_sweep_outlined, color: c.error),
                      title: const Text('Delete all downloads'),
                      enabled: downloads.done.isNotEmpty,
                      onTap: () async {
                        final ok = await confirm(context,
                            title: 'Delete all downloaded chapters?',
                            message: 'They are removed from this phone. '
                                'Your list and progress are kept.',
                            action: 'Delete',
                            destructive: true);
                        if (ok == true) {
                          await ref.read(downloadsProvider.notifier).deleteAll();
                        }
                      },
                    ),
                  ]),
                ),
              ],

              // ---- Your data ----
              const SectionLabel('Your data'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('Import titles'),
                    subtitle: const Text('From an Excel / CSV file or a pasted list'),
                    onTap: () => _import(context, ref),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.copy_all_rounded),
                    title: const Text('Copy list to clipboard'),
                    subtitle: const Text(
                        'Title | Chapter | Status | Type | Reread — use it as a backup'),
                    onTap: () async {
                      final entries =
                          ref.read(entriesProvider).value ?? const [];
                      await Clipboard.setData(
                          ClipboardData(text: exportPipeLines(entries)));
                      if (context.mounted) {
                        showSnack(context, 'Copied ${entries.length} titles');
                      }
                    },
                  ),
                ]),
              ),

              // ---- About ----
              const SectionLabel('About'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.system_update_rounded),
                    title: const Text('Check for updates'),
                    subtitle: Text(switch (ref.watch(appVersionProvider).value) {
                      final v? => 'Version $v',
                      null => 'Get the latest version from GitHub',
                    }),
                    onTap: () => checkForUpdates(context, ref, manual: true),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.help_outline_rounded),
                    title: const Text('Contact support'),
                    subtitle: const Text(AppConfig.supportEmail),
                    onTap: () => launchUrl(
                        Uri.parse('mailto:${AppConfig.supportEmail}')),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.gavel_rounded),
                    title: const Text('Legal terms & disclaimer'),
                    subtitle: const Text(
                        'Third-party sources, your responsibility, no warranty'),
                    onTap: () => openLegalTerms(context),
                  ),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  static Future<String> _folderLabel() async {
    final dir = await DownloadStore.root();
    if (dir == null) return '';
    final p = dir.path;
    // Show the part people can find in a file manager.
    final i = p.indexOf('Android/data/');
    return i >= 0 ? p.substring(i) : p;
  }

  static String _bytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  Future<void> _import(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _ImportSheet(),
    );
  }
}

class _ImportSheet extends ConsumerStatefulWidget {
  const _ImportSheet();

  @override
  ConsumerState<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<_ImportSheet> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _fileName;
  ParseResult _parsed = const ParseResult([], []);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  ImportPlan get _plan => planImport(
      ref.read(entriesProvider).value ?? const <Entry>[], _parsed.entries);

  Future<void> _pickFile() async {
    try {
      final sheet = await pickSheetFile();
      if (sheet == null || !mounted) return;
      setState(() {
        _fileName = sheet.name;
        _text.clear();
        _parsed = parseSheetRows(sheet.rows);
      });
      if (_parsed.entries.isEmpty && mounted) {
        showSnack(context, 'No titles found in ${sheet.name}', error: true);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context,
            e is FormatException ? e.message : friendlyError(e), error: true);
      }
    }
  }

  Future<void> _run() async {
    final plan = _plan;
    if (plan.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(entriesProvider.notifier).applyImport(plan);
      if (!mounted) return;
      Navigator.of(context).pop();
      final parts = [
        if (r.added > 0) 'added ${r.added}',
        if (r.updated > 0) 'updated ${r.updated}',
        if (plan.skipped > 0) 'skipped ${plan.skipped} already in your list',
      ];
      final msg = parts.join(', ');
      showSnack(context, '${msg[0].toUpperCase()}${msg.substring(1)}');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Re-plan whenever the list changes.
    ref.watch(entriesProvider);
    final plan = _plan;
    final hasInput = _parsed.entries.isNotEmpty || _parsed.errors.isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Import titles', style: context.text.headlineSmall),
            const SizedBox(height: 14),

            // ---- From a file ----
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.table_chart_outlined),
              label: Text(_fileName ?? 'Choose Excel or CSV file'),
            ),
            const SizedBox(height: 6),
            Text(
              'Columns: Title, Chapter, Status, Type, Reread. '
              'A header row is optional; only Title is required.',
              style: context.text.bodySmall
                  ?.copyWith(color: c.onSurfaceVariant),
            ),

            const SizedBox(height: 14),
            Row(children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('or paste',
                    style: context.text.labelMedium
                        ?.copyWith(color: c.onSurfaceVariant)),
              ),
              const Expanded(child: Divider()),
            ]),
            const SizedBox(height: 10),

            // ---- Pasted text ----
            Text(
              'Solo Leveling | 120 | Reading | Manhwa | 0\n'
              'Solo Leveling 120 Reading Manhwa 0',
              style: context.text.bodySmall?.copyWith(
                  color: c.onSurfaceVariant,
                  fontFamily: 'monospace',
                  height: 1.5),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 8,
              enabled: !_busy,
              onChanged: (v) => setState(() {
                _fileName = null;
                _parsed = parseImportText(v);
              }),
              decoration:
                  const InputDecoration(hintText: 'Paste your list here'),
            ),

            // ---- Preview ----
            if (hasInput) ...[
              const SizedBox(height: 12),
              _PlanSummary(
                  plan: plan, errors: _parsed.errors.length),
              for (final err in _parsed.errors.take(3))
                Text(err,
                    style: context.text.bodySmall?.copyWith(color: c.error)),
            ],
            const SizedBox(height: 8),
            Text(
              'Covers are found automatically after importing.',
              style: context.text.bodySmall
                  ?.copyWith(color: c.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
            ],
            FilledButton(
              onPressed: _busy || plan.isEmpty ? null : _run,
              child: Text(plan.isEmpty
                  ? 'Import'
                  : 'Import ${plan.toAdd.length + plan.toUpdate.length} titles'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "12 new · 3 will update chapters · 5 already in your list".
class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.plan, required this.errors});
  final ImportPlan plan;
  final int errors;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget line(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: context.text.bodyMedium)),
          ]),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(Icons.add_circle_outline_rounded, c.primary,
            '${plan.toAdd.length} new'),
        if (plan.toUpdate.isNotEmpty)
          line(Icons.trending_up_rounded, c.tertiary,
              '${plan.toUpdate.length} already in your list, will move to the higher chapter'),
        if (plan.skipped > 0)
          line(Icons.check_circle_outline_rounded, c.onSurfaceVariant,
              '${plan.skipped} already in your list, skipped'),
        if (plan.mergedInFile > 0)
          line(Icons.call_merge_rounded, c.onSurfaceVariant,
              '${plan.mergedInFile} repeated rows merged (kept the higher chapter)'),
        if (errors > 0)
          line(Icons.error_outline_rounded, c.error, '$errors rows skipped'),
      ],
    );
  }
}
