import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/app_lock.dart';
import '../state/providers.dart';
import '../theme.dart';

/// Shown instead of the app while it's locked. Opens the fingerprint / face
/// prompt straight away; the button reopens it if it was dismissed.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await ref.read(appLockProvider.notifier).unlock();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _signOut() async {
    final db = ref.read(supabaseProvider);
    try {
      await db.auth.signOut();
    } catch (_) {
      await db.auth.signOut(scope: SignOutScope.local);
    }
    ref.read(appLockProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final email = ref.watch(userEmailProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset('assets/logo.png', width: 72, height: 72),
                ),
                const SizedBox(height: 18),
                Text('MyReadList is locked',
                    style: context.text.headlineSmall,
                    textAlign: TextAlign.center),
                if (email != null) ...[
                  const SizedBox(height: 6),
                  Text(email,
                      style: context.text.bodyMedium
                          ?.copyWith(color: c.onSurfaceVariant)),
                ],
                const SizedBox(height: 36),
                IconButton.filledTonal(
                  iconSize: 44,
                  padding: const EdgeInsets.all(18),
                  tooltip: 'Unlock',
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.fingerprint_rounded),
                ),
                const SizedBox(height: 12),
                Text('Use fingerprint, face or your phone PIN',
                    style: context.text.bodySmall
                        ?.copyWith(color: c.onSurfaceVariant)),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall?.copyWith(color: c.error)),
                ],
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : _signOut,
                  child: const Text('Sign in with password instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
