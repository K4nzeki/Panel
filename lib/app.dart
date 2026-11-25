import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/reset_password_screen.dart';
import 'state/providers.dart';
import 'theme.dart';

class MyReadListApp extends ConsumerWidget {
  const MyReadListApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'MyReadList',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (_, next) {
      final event = next.value?.event;
      if (event == AuthChangeEvent.passwordRecovery) {
        ref.read(passwordRecoveryProvider.notifier).state = true;
      } else if (event == AuthChangeEvent.signedOut) {
        ref.read(passwordRecoveryProvider.notifier).state = false;
      }
    });

    final uid = ref.watch(userIdProvider);
    final recovering = ref.watch(passwordRecoveryProvider);

    final Widget child;
    if (uid != null && recovering) {
      child = const ResetPasswordScreen();
    } else if (uid != null) {
      child = const HomeShell();
    } else {
      child = const AuthScreen();
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
  }
}
