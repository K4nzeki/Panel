/// Supabase connection settings.
///
/// These are the same public values the web app ships with (a Supabase
/// *publishable* key is meant to live in client apps — your data is
/// protected by Row Level Security, not by hiding this key).
///
/// Override at build time without editing code:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://wijvkytvsdaoiwnejobj.supabase.co',
  );

  static const supabaseKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_ebpIKAWnU4FtcB1Zh4XZ3Q_nlIV-YRK',
  );

  /// Deep link the auth emails (confirm sign-up, reset password) send the
  /// user back to. Must also be added to Supabase → Authentication →
  /// URL Configuration → Redirect URLs, and to AndroidManifest.xml / Info.plist
  /// (see README.md).
  static const authRedirect = 'com.readlist.panel://login-callback';

  static const supportEmail = 'support@myreadlist.app';
}
