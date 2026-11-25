import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shown after the user opens a password-reset link from their email.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(supabaseProvider)
          .auth
          .updateUser(UserAttributes(password: _pw.text));
      ref.read(passwordRecoveryProvider.notifier).state = false;
      if (mounted) showSnack(context, 'Password updated');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a new password'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () =>
              ref.read(passwordRecoveryProvider.notifier).state = false,
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Pick something you haven’t used before. At least 6 characters.',
              style: context.text.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _pw,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'New password'),
              validator: (v) =>
                  (v ?? '').length < 6 ? 'At least 6 characters' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pw2,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              validator: (v) => v != _pw.text ? 'Passwords don’t match' : null,
              onFieldSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Text('Save password'),
            ),
          ],
        ),
      ),
    );
  }
}
