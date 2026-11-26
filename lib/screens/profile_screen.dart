import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/entry.dart';
import '../services/sheet_file.dart';
import '../state/app_lock.dart';
import '../state/extensions.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/import_merge.dart';
import '../utils/import_parser.dart';
import '../utils/sheet_import.dart';
import '../widgets/common.dart';
import '../widgets/entry_sheet.dart';
import '../widgets/update_dialog.dart';
import 'community_screen.dart';
import 'extension_store_screen.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final email = ref.watch(userEmailProvider) ?? '';
    final themeMode = ref.watch(themeModeProvider);
    final c = context.colors;
    final p = profile.value;
    final name = p?.username ?? email.split('@').first;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            toolbarHeight: 72,
            titleSpacing: 20,
            title: Text('Profile'),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            sliver: SliverList.list(children: [
              // ---- Identity card ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: c.primary,
                      child: Text(
                        name.isEmpty ? '?' : name[0].toUpperCase(),
                        style: context.text.headlineSmall
                            ?.copyWith(color: c.onPrimary),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p?.username != null ? '@${p!.username}' : name,
                              style: context.text.titleLarge),
                          const SizedBox(height: 2),
                          Text(email,
                              style: context.text.bodySmall
                                  ?.copyWith(color: c.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Edit username',
                      onPressed: () => _editUsername(context, ref, p),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ]),
                ),
              ),

              // ---- Sharing ----
              const SectionLabel('Sharing'),
              Card(
                child: Column(children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.public_rounded),
                    title: const Text('Public list'),
                    subtitle: Text(p?.username == null
                        ? 'Set a username first so others can find you'
                        : 'Other readers can browse your list'),
                    value: p?.listVisible ?? true,
                    onChanged: p == null
                        ? null
                        : (v) => _saveProfile(context, ref,
                            username: p.username, listVisible: v),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.people_outline_rounded),
                    title: const Text('Browse readers'),
                    subtitle: const Text('See what others are reading'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const CommunityScreen())),
                  ),
                ]),
              ),

              // ---- Security ----
              const SectionLabel('Security'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Unlock with fingerprint / face'),
                  subtitle: const Text(
                      'Stay signed in and open the app without your password'),
                  value: ref.watch(appLockProvider.select((s) => s.enabled)),
                  onChanged: (v) async {
                    final err =
                        await ref.read(appLockProvider.notifier).setEnabled(v);
                    if (context.mounted && err != null) {
                      showSnack(context, err, error: true);
                    } else if (context.mounted && v &&
                        ref.read(appLockProvider).enabled) {
                      showSnack(context, 'App lock is on');
                    }
                  },
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
              const SectionLabel('Extensions'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('Extension store'),
                  subtitle: Text(switch (ref.watch(extensionStoreProvider)) {
                    final s when s.repoUrls.isEmpty =>
                      'Add a repo link to download extensions',
                    final s =>
                      '${s.extensions.where(s.isInstalled).length} installed · '
                          '${s.repoUrls.length} repo${s.repoUrls.length == 1 ? '' : 's'}',
                  }),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ExtensionStoreScreen())),
                ),
              ),

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
                    subtitle: const Text('Title | Chapter | Status | Type | Reread'),
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

              // ---- Account ----
              const SectionLabel('Account'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.mail_outline_rounded),
                    title: const Text('Change email'),
                    onTap: () => _changeEmail(context, ref, email),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: const Text('Change password'),
                    onTap: () => _changePassword(context, ref),
                  ),
                  const Divider(indent: 16, endIndent: 16),
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
                ]),
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final pending = ref.read(pendingCountProvider);
                  final ok = await confirm(context,
                      title: pending > 0
                          ? 'Sign out with $pending unsynced '
                              '${pending == 1 ? 'change' : 'changes'}?'
                          : 'Sign out?',
                      action: 'Sign out');
                  if (ok == true) {
                    await ref.read(repositoryProvider)?.clearCache();
                    try {
                      await ref.read(supabaseProvider).auth.signOut();
                    } catch (_) {
                      // Offline: still sign out on this phone.
                      await ref
                          .read(supabaseProvider)
                          .auth
                          .signOut(scope: SignOutScope.local);
                    }
                  }
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Sign out'),
              ),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.error),
                onPressed: () => _deleteAccount(context, ref),
                child: const Text('Delete account'),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _saveProfile(BuildContext context, WidgetRef ref,
      {String? username, required bool listVisible}) async {
    final uid = ref.read(userIdProvider);
    if (uid == null) return;
    try {
      await ref.read(supabaseProvider).from('profiles').upsert(
        {'id': uid, 'username': username, 'list_visible': listVisible},
        onConflict: 'id',
      );
      ref.invalidate(profileProvider);
    } on PostgrestException catch (e) {
      if (context.mounted) {
        showSnack(
            context,
            e.code == '23505'
                ? 'That username is already taken.'
                : e.message,
            error: true);
      }
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _editUsername(
      BuildContext context, WidgetRef ref, Profile? p) async {
    final v = await promptText(context,
        title: 'Username', initial: p?.username ?? '', hint: 'letters, numbers, _');
    if (v == null || !context.mounted) return;
    final u = v.trim();
    if (u.isNotEmpty && !RegExp(r'^[A-Za-z0-9_]{3,40}$').hasMatch(u)) {
      showSnack(context, 'Use 3–40 letters, numbers or _', error: true);
      return;
    }
    if (u == (p?.username ?? '')) return;
    await _saveProfile(context, ref,
        username: u.isEmpty ? null : u, listVisible: p?.listVisible ?? true);
    if (context.mounted) showSnack(context, 'Username saved');
  }

  Future<void> _changeEmail(
      BuildContext context, WidgetRef ref, String current) async {
    final v = await promptText(context,
        title: 'New email',
        initial: current,
        keyboard: TextInputType.emailAddress);
    if (v == null || v.trim().isEmpty || v.trim() == current) return;
    try {
      await ref.read(supabaseProvider).auth.updateUser(
            UserAttributes(email: v.trim()),
            emailRedirectTo: AppConfig.authRedirect,
          );
      if (context.mounted) {
        showSnack(context, 'Check your new inbox to confirm the change.');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final v = await promptText(context, title: 'New password (6+ characters)');
    if (v == null || v.isEmpty) return;
    if (v.length < 6) {
      if (context.mounted) {
        showSnack(context, 'Password must be at least 6 characters.',
            error: true);
      }
      return;
    }
    try {
      await ref
          .read(supabaseProvider)
          .auth
          .updateUser(UserAttributes(password: v));
      if (context.mounted) showSnack(context, 'Password updated');
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final typed = await promptText(context,
        title: 'Delete your account?',
        hint: 'Type DELETE to confirm');
    if (typed?.trim() != 'DELETE') {
      if (typed != null && context.mounted) {
        showSnack(context, 'Account not deleted.');
      }
      return;
    }
    try {
      final db = ref.read(supabaseProvider);
      await db.rpc('delete_own_account');
      await ref.read(repositoryProvider)?.clearCache();
      await db.auth.signOut();
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
    }
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
    // Re-plan whenever the list changes (e.g. a sync finishes).
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
