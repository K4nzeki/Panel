import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config.dart';
import 'services/background.dart';
import 'state/app_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    throw StateError(
      'Supabase keys missing. Copy env.example.json to env.json, fill it in, '
      'and run with --dart-define-from-file=env.json',
    );
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseKey,
  );
  final prefs = await SharedPreferences.getInstance();
  // New-chapter checks every 5 hours while the app is closed (Android).
  // A failure here must never stop the app from opening.
  try {
    await Background.init();
  } catch (_) {}
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Background.requestPermission().catchError((_) {});
  });
  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MyReadListApp(),
  ));
}
