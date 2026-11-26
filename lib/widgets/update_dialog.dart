import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/updater.dart';
import '../state/app_lock.dart';
import 'common.dart';

final updaterProvider = Provider<Updater>((ref) => Updater());

/// The installed version, for showing in Profile.
final appVersionProvider = FutureProvider<String?>((ref) async {
  if (!Updater.supported) return null;
  try {
    return await ref.read(updaterProvider).currentVersion();
  } catch (_) {
    return null;
  }
});

const _lastCheckKey = 'update_last_check';

/// Looks for a newer GitHub release and offers to install it.
///
/// [manual] is for the "Check for updates" button: it always checks and
/// says "You're up to date" / shows errors. The automatic check on launch
/// runs at most every 12 hours and stays quiet unless there's an update.
Future<void> checkForUpdates(BuildContext context, WidgetRef ref,
    {bool manual = false}) async {
  if (!Updater.supported) {
    if (manual) await launchUrl(Uri.parse(Updater.releasesPage));
    return;
  }
  final prefs = ref.read(sharedPrefsProvider);
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!manual) {
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    if (now - last < const Duration(hours: 12).inMilliseconds) return;
  }

  AppRelease? release;
  try {
    release = await ref.read(updaterProvider).checkForUpdate();
    await prefs.setInt(_lastCheckKey, now);
  } catch (e) {
    if (manual && context.mounted) {
      showSnack(
          context, e is UpdateException ? e.message : "Couldn't check for updates.",
          error: true);
    }
    return;
  }
  if (!context.mounted) return;
  if (release == null) {
    if (manual) showSnack(context, "You're on the latest version");
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(release: release!),
  );
}

class _UpdateDialog extends ConsumerStatefulWidget {
  const _UpdateDialog({required this.release});
  final AppRelease release;

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  bool _downloading = false;
  double? _progress;
  String? _apkPath;
  String? _error;

  Future<void> _update() async {
    final updater = ref.read(updaterProvider);
    setState(() {
      _error = null;
      _downloading = _apkPath == null;
      _progress = null;
    });
    try {
      _apkPath ??= await updater.download(widget.release,
          onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _downloading = false);
      final opened = await updater.install(_apkPath!);
      if (!opened && mounted) {
        setState(() => _error =
            'Allow "Install unknown apps" for Panel, then come back and tap Install.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = e is UpdateException ? e.message : 'Download failed. Check your connection.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final c = Theme.of(context).colorScheme;
    final ready = _apkPath != null;
    return AlertDialog(
      title: Text('Update to ${r.version}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.notes.isNotEmpty)
              Text(r.notes, style: Theme.of(context).textTheme.bodyMedium)
            else
              const Text('A new version of Panel is available.'),
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Text(
                _progress == null
                    ? 'Downloading…'
                    : 'Downloading… ${(_progress! * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.error)),
            ],
            if (r.apkUrl == null) ...[
              const SizedBox(height: 12),
              Text('No APK is attached to this release yet.',
                  style: TextStyle(color: c.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        if (r.apkUrl == null)
          FilledButton(
            onPressed: () => launchUrl(Uri.parse(Updater.releasesPage),
                mode: LaunchMode.externalApplication),
            child: const Text('Open GitHub'),
          )
        else
          FilledButton(
            onPressed: _downloading ? null : _update,
            child: Text(ready ? 'Install' : 'Update'),
          ),
      ],
    );
  }
}
