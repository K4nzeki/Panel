import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'anilist.dart';
import 'extension_covers.dart';
import 'inbox.dart';
import 'local_store.dart';
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

/// Runs in a separate isolate started by Android's WorkManager. Reads the
/// list saved on the phone and saves what it finds as patches the app picks
/// up next time it opens (see [LocalStore]).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final entries = await LocalStore.readEntries();
      if (entries.isEmpty) return true;

      await Notifications.init();
      final checker = UpdateChecker();
      // New chapters for what you're reading (skipped if the app already
      // checked in the last 5 hours), then covers for titles missing one.
      // Progress shows as a quiet notification instead of in the app.
      if (await checker.isDue()) {
        try {
          final updates = await checker.run(
            entries,
            LocalStore.addBackgroundPatch,
            onProgress: (done, total) => Notifications.showProgress(
                Notifications.chaptersProgressId, 'Checking for new chapters',
                done: done, total: total),
          );
          await Notifications.showUpdates(updates);
        } on UpdateOffline {
          return true; // WorkManager only runs us when online; try next time
        } finally {
          await Notifications.endProgress(Notifications.chaptersProgressId);
        }
      }
      try {
        await checker.fillCovers(
          await LocalStore.readEntries(),
          LocalStore.addBackgroundPatch,
          AniListService(),
          extensions: await ExtensionCoverFinder.load(),
          onProgress: (done, total) => Notifications.showProgress(
              Notifications.coversProgressId, 'Finding covers',
              done: done, total: total),
        );
      } finally {
        await Notifications.endProgress(Notifications.coversProgressId);
      }
      return true;
    } catch (_) {
      return false; // WorkManager retries later
    }
  });
}

class Notifications {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  // Fixed ids for the "working on it" notifications.
  static const chaptersProgressId = 9001;
  static const coversProgressId = 9002;
  static const downloadProgressId = 9003;

  /// Payload of the summary notification: opens the Updates tab.
  static const updatesPayload = 'updates';

  /// Set when a notification is tapped while the app is running. Holds the
  /// series id, or [updatesPayload]. The home screen listens and clears it.
  static final tapped = ValueNotifier<String?>(null);

  static Future<void> init() async {
    if (_ready || !Background.supported) return;
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null && p.isNotEmpty) tapped.value = p;
      },
    );
    _ready = true;
  }

  /// The payload of the notification that opened the app, if any. Only
  /// returns it once so reopening the screen doesn't repeat it.
  static bool _launchHandled = false;
  static Future<String?> launchPayload() async {
    if (_launchHandled || !Background.supported) return null;
    _launchHandled = true;
    await init();
    final details = await plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final p = details?.notificationResponse?.payload;
    return (p == null || p.isEmpty) ? null : p;
  }

  static const _chapterChannel = AndroidNotificationDetails(
    'new_chapters',
    'New chapters',
    channelDescription: 'When a series you are reading has new chapters',
    importance: Importance.high,
    priority: Priority.high,
    groupKey: 'panel.new_chapters',
  );

  /// Saves the alerts for the Updates tab, then shows one notification per
  /// series (tap opens it) plus a summary when there are several.
  static Future<void> showUpdates(List<SeriesUpdate> updates) async {
    if (updates.isEmpty) return;
    await Inbox.add(updates);
    if (!Background.supported) return;
    await init();
    for (final u in updates.take(10)) {
      final n = u.unread;
      await plugin.show(
        u.entry.id.hashCode & 0x7fffffff,
        u.entry.title,
        'Chapter ${u.latest} is out · $n new chapter${n == 1 ? '' : 's'} to read',
        const NotificationDetails(android: _chapterChannel),
        payload: u.entry.id,
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
            importance: Importance.high,
            priority: Priority.high,
            groupKey: 'panel.new_chapters',
            setAsGroupSummary: true,
          ),
        ),
        payload: updatesPayload,
      );
    }
  }

  // Progress notifications go out one at a time, in order, so a late
  // "update" can never land after the "done" and leave a stuck notification.
  static Future<void> _queue = Future<void>.value();
  static final Map<int, DateTime> _lastProgress = {};

  static Future<void> _serial(Future<void> Function() op) {
    final next = _queue.then((_) => op()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  /// A quiet, ongoing notification for work in progress (checking chapters,
  /// finding covers, downloading). No sound or vibration; updates in place, at
  /// most about twice a second (Android drops faster updates). Leave
  /// [total] null for a spinner-style bar.
  static Future<void> showProgress(int id, String title,
      {int? done, int? total}) {
    if (!Background.supported) return Future<void>.value();
    final now = DateTime.now();
    final last = _lastProgress[id];
    if (last != null && now.difference(last).inMilliseconds < 500) {
      return Future<void>.value();
    }
    _lastProgress[id] = now;
    final max = (total != null && total > 0) ? total : 0;
    final d = done ?? 0;
    final at = d < 0 ? 0 : (d > max ? max : d);
    final known = max > 0 && done != null;
    return _serial(() async {
      await init();
      await plugin.show(
        id,
        title,
        known ? '$at of $max' : null,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'background_work',
            'Background activity',
            channelDescription:
                'Shows while Panel checks chapters, finds covers or downloads',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            silent: true,
            showWhen: false,
            showProgress: true,
            maxProgress: max,
            progress: at,
            indeterminate: !known,
          ),
        ),
        payload: updatesPayload,
      );
    });
  }

  static Future<void> endProgress(int id) {
    if (!Background.supported) return Future<void>.value();
    _lastProgress.remove(id);
    return _serial(() => plugin.cancel(id));
  }
}
