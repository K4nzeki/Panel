import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'update_checker.dart';

/// One "new chapter" alert shown on the Updates tab.
class ChapterAlert {
  const ChapterAlert({
    required this.entryId,
    required this.title,
    required this.latest,
    required this.unread,
    required this.at,
    this.coverUrl,
    this.read = false,
  });

  final String entryId;
  final String title;
  final String? coverUrl;

  /// Newest chapter out when the alert was made.
  final int latest;

  /// Chapters you hadn't read at that time.
  final int unread;
  final DateTime at;
  final bool read;

  ChapterAlert copyWith({bool? read}) => ChapterAlert(
        entryId: entryId,
        title: title,
        coverUrl: coverUrl,
        latest: latest,
        unread: unread,
        at: at,
        read: read ?? this.read,
      );

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'title': title,
        'cover_url': coverUrl,
        'latest': latest,
        'unread': unread,
        'at': at.millisecondsSinceEpoch,
        'read': read,
      };

  static ChapterAlert? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['entry_id'], title = raw['title'], at = raw['at'];
    if (id is! String || title is! String || at is! int) return null;
    return ChapterAlert(
      entryId: id,
      title: title,
      coverUrl: raw['cover_url'] as String?,
      latest: (raw['latest'] as num?)?.toInt() ?? 0,
      unread: (raw['unread'] as num?)?.toInt() ?? 0,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      read: raw['read'] == true,
    );
  }
}

/// Saved "new chapter" alerts, kept on the phone per account. Written by the
/// in-app check and by the background job (a separate isolate), so every
/// read reloads from storage first.
class Inbox {
  static const max = 100;
  static String _key(String userId) => 'inbox_v1_$userId';

  static Future<List<ChapterAlert>> load(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key(userId));
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final j in list)
          if (ChapterAlert.fromJson(j) case final a?) a,
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String userId, List<ChapterAlert> alerts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(userId),
        jsonEncode([for (final a in alerts.take(max)) a.toJson()]));
  }

  /// Adds alerts for [updates], newest first. A series keeps one alert: a
  /// newer chapter replaces the older alert for it.
  static Future<List<ChapterAlert>> add(
      String userId, List<SeriesUpdate> updates) async {
    final current = await load(userId);
    if (updates.isEmpty) return current;
    final now = DateTime.now();
    final fresh = [
      for (final u in updates)
        ChapterAlert(
          entryId: u.entry.id,
          title: u.entry.title,
          coverUrl: u.entry.coverUrl,
          latest: u.latest,
          unread: u.unread,
          at: now,
        ),
    ];
    final ids = {for (final a in fresh) a.entryId};
    final next = [...fresh, ...current.where((a) => !ids.contains(a.entryId))];
    await save(userId, next);
    return next;
  }
}
