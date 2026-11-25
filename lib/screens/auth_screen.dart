import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../models/entry.dart';
import '../state/providers.dart';
import '../theme.dart';

enum _Mode { signIn, signUp, forgot }

enum _NameStatus { idle, checking, available, taken, invalid }

final _usernameRe = RegExp(r'^[A-Za-z0-9_]{3,40}$');

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _login = TextEditingController(); // email or username
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _showPassword = false;
  String? _message;
  bool _messageIsError = true;
  _NameStatus _nameStatus = _NameStatus.idle;
  Timer? _nameDebounce;

  @override
  void dispose() {
    _nameDebounce?.cancel();
    for (final c in [_login, _email, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _switch(_Mode m) => setState(() {
        _mode = m;
        _message = null;
        _form.currentState?.reset();
      });

  void _onUsernameChanged(String v) {
    _nameDebounce?.cancel();
    final u = v.trim();
    if (u.isEmpty) {
      setState(() => _nameStatus = _NameStatus.idle);
      return;
    }
    if (!_usernameRe.hasMatch(u)) {
      setState(() => _nameStatus = _NameStatus.invalid);
      return;
    }
    setState(() => _nameStatus = _NameStatus.checking);
    _nameDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final ok = await ref
            .read(supabaseProvider)
            .rpc('username_available', params: {'p_username': u});
        if (!mounted || _username.text.trim() != u) return;
        setState(() => _nameStatus =
            ok == true ? _NameStatus.available : _NameStatus.taken);
      } catch (_) {
        if (mounted) setState(() => _nameStatus = _NameStatus.idle);
      }
    });
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _message = null;
    });
    final db = ref.read(supabaseProvider);
    try {
      switch (_mode) {
        case _Mode.signIn:
          var email = _login.text.trim();
          if (!email.contains('@')) {
            final resolved = await db
                .rpc('email_for_username', params: {'p_username': email});
            if (resolved == null || resolved.toString().isEmpty) {
              throw Exception('Invalid login credentials');
            }
            email = resolved.toString();
          }
          await db.auth
              .signInWithPassword(email: email, password: _password.text);
        case _Mode.signUp:
          final uname = _username.text.trim();
          final available = await db
              .rpc('username_available', params: {'p_username': uname});
          if (available != true) {
            throw Exception('That username is already taken.');
          }
          await db.auth.signUp(
            email: _email.text.trim(),
            password: _password.text,
            data: {'username': uname},
            emailRedirectTo: AppConfig.authRedirect,
          );
          _show('Check your email to confirm, then sign in.', error: false);
          _mode = _Mode.signIn;
          _login.text = uname;
          _password.clear();
        case _Mode.forgot:
          var target = _login.text.trim();
          if (!target.contains('@')) {
            final resolved = await db
                .rpc('email_for_username', params: {'p_username': target});
            if (resolved != null) target = resolved.toString();
          }
          await db.auth
              .resetPasswordForEmail(target, redirectTo: AppConfig.authRedirect);
          // Same message either way so this can't reveal who has an account.
          _show('If that account exists, a reset link is on its way.',
              error: false);
      }
    } catch (e) {
      _show(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String msg, {bool error = true}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _messageIsError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSignUp = _mode == _Mode.signUp;
    final isForgot = _mode == _Mode.forgot;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.primary.withValues(alpha: 0.16), c.surface],
            stops: const [0, 0.45],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Brand(),
                    const SizedBox(height: 32),
                    if (!isForgot)
                      SegmentedButton<_Mode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: _Mode.signIn, label: Text('Sign in')),
                          ButtonSegment(
                              value: _Mode.signUp,
                              label: Text('Create account')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => _switch(s.first),
                      )
                    else
                      Row(children: [
                        IconButton(
                          onPressed: () => _switch(_Mode.signIn),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Text('Reset password', style: context.text.titleLarge),
                      ]),
                    const SizedBox(height: 20),
                    Form(
                      key: _form,
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (isSignUp) ...[
                              TextFormField(
                                controller: _username,
                                autofillHints: const [AutofillHints.newUsername],
                                onChanged: _onUsernameChanged,
                                decoration: InputDecoration(
                                  labelText: 'Username',
                                  prefixIcon:
                                      const Icon(Icons.alternate_email_rounded),
                                  suffixIcon: _NameStatusIcon(_nameStatus),
                                  helperText: switch (_nameStatus) {
                                    _NameStatus.taken => 'Already taken',
                                    _NameStatus.available => 'Available',
                                    _ => 'Letters, numbers and _ (3–40)',
                                  },
                                ),
                                validator: (v) {
                                  final u = v?.trim() ?? '';
                                  if (!_usernameRe.hasMatch(u)) {
                                    return '3–40 letters, numbers or _';
                                  }
                                  if (_nameStatus == _NameStatus.taken) {
                                    return 'That username is taken';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: Icon(Icons.mail_outline_rounded),
                                ),
                                validator: (v) => (v ?? '').contains('@')
                                    ? null
                                    : 'Enter a valid email',
                              ),
                            ] else
                              TextFormField(
                                controller: _login,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [
                                  AutofillHints.username,
                                  AutofillHints.email
                                ],
                                decoration: const InputDecoration(
                                  labelText: 'Email or username',
                                  prefixIcon: Icon(Icons.person_outline_rounded),
                                ),
                                validator: (v) => (v ?? '').trim().isEmpty
                                    ? 'Required'
                                    : null,
                              ),
                            if (!isForgot) ...[
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _password,
                                obscureText: !_showPassword,
                                autofillHints: [
                                  isSignUp
                                      ? AutofillHints.newPassword
                                      : AutofillHints.password
                                ],
                                onFieldSubmitted: (_) => _submit(),
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon:
                                      const Icon(Icons.lock_outline_rounded),
                                  suffixIcon: IconButton(
                                    tooltip: _showPassword ? 'Hide' : 'Show',
                                    onPressed: () => setState(
                                        () => _showPassword = !_showPassword),
                                    icon: Icon(_showPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined),
                                  ),
                                ),
                                validator: (v) {
                                  if ((v ?? '').isEmpty) return 'Required';
                                  if (isSignUp && v!.length < 6) {
                                    return 'At least 6 characters';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (_mode == _Mode.signIn)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => _switch(_Mode.forgot),
                          child: const Text('Forgot password?'),
                        ),
                      )
                    else
                      const SizedBox(height: 16),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _message == null
                          ? const SizedBox(width: double.infinity)
                          : Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _messageIsError
                                    ? c.errorContainer
                                    : c.primary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(children: [
                                Icon(
                                  _messageIsError
                                      ? Icons.error_outline_rounded
                                      : Icons.check_circle_outline_rounded,
                                  color: _messageIsError
                                      ? c.onErrorContainer
                                      : c.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _message!,
                                    style: TextStyle(
                                      color: _messageIsError
                                          ? c.onErrorContainer
                                          : c.onSurface,
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                    ),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4))
                          : Text(switch (_mode) {
                              _Mode.signIn => 'Sign in',
                              _Mode.signUp => 'Create account',
                              _Mode.forgot => 'Send reset link',
                            }),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Your list syncs across devices. Only you can see it unless you make it public.',
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall
                          ?.copyWith(color: c.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: c.primary,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: c.primary.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Icon(Icons.auto_stories_rounded, size: 38, color: c.onPrimary),
        ),
        const SizedBox(height: 18),
        Text('MyReadList', style: context.text.headlineMedium),
        const SizedBox(height: 6),
        Text(
          'Track every manga, manhwa, manhua\nand comic you read.',
          textAlign: TextAlign.center,
          style: context.text.bodyLarge?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _NameStatusIcon extends StatelessWidget {
  const _NameStatusIcon(this.status);
  final _NameStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return switch (status) {
      _NameStatus.checking => const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      _NameStatus.available =>
        Icon(Icons.check_circle_rounded,
            color: context.statusColors.of(EntryStatus.finished)),
      _NameStatus.taken || _NameStatus.invalid =>
        Icon(Icons.cancel_rounded, color: c.error),
      _NameStatus.idle => const SizedBox.shrink(),
    };
  }
}
