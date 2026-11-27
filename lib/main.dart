import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/background.dart';
import 'services/cover_cache.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Saved covers show from the very first frame, even offline.
  await CoverCache.init();
  // New-chapter checks every 5 hours while the app is closed (Android).
  // Set up after the first frame, not before it: WorkManager and the
  // notifications plugin each take a round trip to Android, and waiting on
  // them kept the splash screen up. (Anything that shows a notification
  // sets the plugin up itself first.) A failure here must never stop the
  // app from opening.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await Background.init();
    } catch (_) {}
    Background.requestPermission().catchError((_) {});
  });
  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const MyReadListApp(),
  ));
}