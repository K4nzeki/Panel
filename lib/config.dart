/// Supabase connection settings.
///
/// The URL and key are NOT stored in this file (so they never reach GitHub).
/// They come from `env.json` at build time — that file is in .gitignore.
///
///   flutter run --dart-define-from-file=env.json
///   flutter build apk --release --dart-define-from-file=env.json
///
/// Copy `env.example.json` to `env.json` and fill in your values.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_KEY');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabaseKey.isNotEmpty &&
      !supabaseKey.contains('your_key_here'); // still the env.example.json placeholder

  /// Deep link the auth emails (confirm sign-up, reset password) send the
  /// user back to. Must also be added to Supabase → Authentication →
  /// URL Configuration → Redirect URLs, and to AndroidManifest.xml / Info.plist
  /// (see README.md).
  static const authRedirect = 'com.readlist.panel://login-callback';

  static const supportEmail = 'support@myreadlist.app';
}
