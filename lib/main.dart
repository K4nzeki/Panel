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
