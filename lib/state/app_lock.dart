import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Loaded once in main() so the lock is known before the first frame
/// (no flash of the list before the lock screen).
final sharedPrefsProvider = Provider<SharedPreferences>(
    (ref) => throw UnimplementedError('Override in main()'));

@immutable
class AppLockState {
  const AppLockState({required this.enabled, required this.locked});
  final bool enabled;
  final bool locked;

  AppLockState copyWith({bool? enabled, bool? locked}) => AppLockState(
      enabled: enabled ?? this.enabled, locked: locked ?? this.locked);
}

/// "Unlock with fingerprint / face". You stay signed in; when the app opens
/// (or comes back after [_relockAfter] in the background) it asks for your
/// fingerprint, face or phone PIN instead of your password.
class AppLockNotifier extends Notifier<AppLockState> {
  static const _key = 'app_lock_enabled';
  static const _relockAfter = Duration(seconds: 30);

  final _auth = LocalAuthentication();
  bool _authenticating = false;
  DateTime? _hiddenAt;

  @override
  AppLockState build() {
    final listener = AppLifecycleListener(
      onPause: () {
        if (!_authenticating) _hiddenAt = DateTime.now();
      },
      onResume: _onResume,
    );
    ref.onDispose(listener.dispose);

    final enabled = ref.read(sharedPrefsProvider).getBool(_key) ?? false;
    final signedIn = Supabase.instance.client.auth.currentUser != null;
    // Only lock a session that was already open when the app launched —
    // signing in with a password afterwards doesn't need a second check.
    return AppLockState(enabled: enabled, locked: enabled && signedIn);
  }

  void _onResume() {
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    if (!state.enabled || _authenticating || hiddenAt == null) return;
    if (DateTime.now().difference(hiddenAt) >= _relockAfter) {
      state = state.copyWith(locked: true);
    }
  }

  Future<bool> _authenticate(String reason) async {
    if (_authenticating) return false;
    _authenticating = true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Fingerprint/face first; the phone's PIN/pattern is the fallback.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } finally {
      _authenticating = false;
    }
  }

  /// Shows the system fingerprint / face prompt. Returns an error message,
  /// or null on success / when the user just cancelled.
  Future<String?> unlock() async {
    try {
      if (await _authenticate('Unlock MyReadList')) {
        state = state.copyWith(locked: false);
      }
      return null;
    } on LocalAuthException catch (e) {
      return lockErrorMessage(e);
    } on PlatformException catch (e) {
      return e.message ?? 'Unlock failed. Try again.';
    }
  }

  /// Turns the lock on (after a successful check) or off.
  /// Returns an error message, or null on success.
  Future<String?> setEnabled(bool value) async {
    if (value) {
      try {
        if (!await _auth.isDeviceSupported()) {
          return 'This phone has no fingerprint, face or screen lock set up.';
        }
        final ok = await _authenticate('Confirm to turn on app lock');
        if (!ok) return null;
      } on LocalAuthException catch (e) {
        return lockErrorMessage(e);
      } on PlatformException catch (e) {
        return e.message ?? "Couldn't turn on app lock.";
      }
    }
    await ref.read(sharedPrefsProvider).setBool(_key, value);
    state = AppLockState(enabled: value, locked: false);
    return null;
  }

  /// Signing out removes the lock screen for this session.
  void reset() => state = state.copyWith(locked: false);
}

String? lockErrorMessage(LocalAuthException e) {
  switch (e.code) {
    case LocalAuthExceptionCode.userCanceled:
    case LocalAuthExceptionCode.systemCanceled:
      return null;
    case LocalAuthExceptionCode.noBiometricHardware:
    case LocalAuthExceptionCode.noBiometricsEnrolled:
    case LocalAuthExceptionCode.noCredentialsSet:
      return 'Set up a fingerprint, face unlock or screen lock in your '
          "phone's settings first.";
    case LocalAuthExceptionCode.temporaryLockout:
      return 'Too many attempts. Wait a moment and try again.';
    case LocalAuthExceptionCode.biometricLockout:
      return 'Fingerprint is locked. Unlock your phone with its PIN, then '
          'try again.';
    default:
      return e.description ?? 'Unlock failed. Try again.';
  }
}

final appLockProvider =
    NotifierProvider<AppLockNotifier, AppLockState>(AppLockNotifier.new);
