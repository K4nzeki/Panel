import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../config.dart';
import 'anilist.dart';
import 'update_checker.dart';

const _taskName = 'panel-check-updates';

/// Background update checks and "new chapter" notifications (Android only).
class Background {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Called once from main(). Schedules the check every 5 hours, only when
  /// the phone has internet. Android may run it a bit later to save battery.
  static Future<void> init() async {
    if (!supported) return;
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: UpdateChecker.interval,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    await Notifications.init();
  }

  /// Asks for notification permission (Android 13+). Needs the app on screen.
  static Future<void> requestPermission() async {
    if (!supported) return;
    await Notifications.plugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }
}

/// Runs in a separate isolate started by Android's WorkManager, so it sets
/// up Supabase itself. The saved login is read from the phone's storage.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      if (!AppConfig.isConfigured) return true;
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabaseKey,
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      );
      final db = Supabase.instance.client;
      final uid = db.auth.currentUser?.id;
      if (uid == null) return true; // signed out: nothing to check

      final checker = UpdateChecker(db, uid);
      // New chapters for what you're reading (skipped if the app already
      // checked in the last 5 hours), then covers for titles missing one.
      if (await checker.isDue()) {
        final updates = await checker.run();
        await Notifications.init();
        await Notifications.showUpdates(updates);
      }
      await checker.fillCovers(AniListService());
      return true;
    } catch (_) {
      return false; // WorkManager retries later
    }
  });
}

class Notifications {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready || !Background.supported) return;
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _ready = true;
  }

  /// One notification per series, plus a summary when there are several.
  static Future<void> showUpdates(List<SeriesUpdate> updates) async {
    if (updates.isEmpty || !Background.supported) return;
    await init();
    for (final u in updates.take(10)) {
      final n = u.unread;
      await plugin.show(
        u.entry.id.hashCode & 0x7fffffff,
        u.entry.title,
        'Chapter ${u.latest} is out · $n new chapter${n == 1 ? '' : 's'} to read',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'new_chapters',
            'New chapters',
            channelDescription: 'When a series you are reading has new chapters',
            groupKey: 'panel.new_chapters',
          ),
        ),
      );
    }
    if (updates.length > 1) {
      await plugin.show(
        0,
        'New chapters',
        '${updates.length} series you read have new chapters',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'new_chapters',
            'New chapters',
            channelDescription: 'When a series you are reading has new chapters',
            groupKey: 'panel.new_chapters',
            setAsGroupSummary: true,
          ),
        ),
      );
    }
  }
}