import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/entry.dart';
import '../utils/dates.dart';

/// Everything Panel knows about your list, saved on this phone only. There
/// are no accounts and nothing is uploaded.
///
/// The app (UI isolate) is the only writer of the list itself. The
/// background new-chapter job runs in another isolate, so it never rewrites
/// the list: it saves small "patches" (newest chapter, cover, …) under their
/// own key, and the app folds them in when it opens or comes back to the
/// foreground ([takeBackgroundPatches]).
class LocalStore {
  static const _entriesKey = 'entries_local_v1';
  static const _activityKey = 'activity_local_v1';
  static const _bgPatchesKey = 'entries_bg_patches_v1';
  static const _migratedKey = 'local_migrated_v1';

  static Future<SharedPreferences> _prefs({bool reload = false}) async {
    final p = await SharedPreferences.getInstance();
    if (reload) await p.reload();
    return p;
  }

  // ---- The list ----

  /// The saved list with any background patches applied (doesn't consume
  /// them; the background job uses this to see the latest state).
  static Future<List<Entry>> readEntries() async {
    final prefs = await _prefs(reload: true);
    await _migrate(prefs);
    final list = _decodeEntries(prefs.getString(_entriesKey));
    final patches = _decodePatches(prefs.getString(_bgPatchesKey));
    return patches.isEmpty ? list : applyPatches(list, patches);
  }

  static Future<void> writeEntries(List<Entry> entries) async {
    final prefs = await _prefs();
    await prefs.setString(
        _entriesKey, jsonEncode([for (final e in entries) e.toJson()]));
  }

  // ---- Patches from the background job ----

  /// Saves [patch] (entry columns, e.g. `latest_chapter`) for entry [id].
  /// Used only by the background isolate.
  static Future<void> addBackgroundPatch(
      String id, Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    final prefs = await _prefs(reload: true);
    final all = _decodePatches(prefs.getString(_bgPatchesKey));
    all[id] = {...?all[id], ...patch};
    await prefs.setString(_bgPatchesKey, jsonEncode(all));
  }

  /// Returns the background job's patches and clears them, so the app can
  /// apply them to its in-memory list.
  static Future<Map<String, Map<String, dynamic>>> takeBackgroundPatches() async {
    final prefs = await _prefs(reload: true);
    final raw = prefs.getString(_bgPatchesKey);
    if (raw == null) return const {};
    await prefs.remove(_bgPatchesKey);
    return _decodePatches(raw);
  }

  static List<Entry> applyPatches(
      List<Entry> list, Map<String, Map<String, dynamic>> patches) {
    if (patches.isEmpty) return list;
    return [
      for (final e in list)
        if (patches[e.id] case final p?) applyPatch(e, p) else e,
    ];
  }

  /// [patch] uses the same column names as [Entry.toJson].
  static Entry applyPatch(Entry e, Map<String, dynamic> patch) =>
      Entry.fromJson({...e.toJson(), ...patch});

  // ---- Stats (chapters per day, finishes per month) ----

  /// Records what a change from [before] to [after] means for Stats. Same
  /// rules the server used to apply: a move into Finished or an extra
  /// reread is one finish this month; chapters going up count as read
  /// today; going down for a reread counts the new chapter number.
  static Future<void> recordActivity(
      Entry before, Entry after, Map<String, dynamic> patch) async {
    var finishes = 0;
    if (patch.containsKey('status') &&
        before.status != EntryStatus.finished &&
        after.status == EntryStatus.finished) {
      finishes++;
    }
    final rereadDelta =
        patch.containsKey('reread') ? after.reread - before.reread : 0;
    if (rereadDelta > 0) finishes += rereadDelta;

    var chapters = 0;
    if (patch.containsKey('chapter') &&
        after.chapter != before.chapter &&
        !(rereadDelta > 0 && after.chapter < before.chapter)) {
      chapters = after.chapter > before.chapter
          ? after.chapter - before.chapter
          : after.chapter;
    }
    if (finishes <= 0 && chapters <= 0) return;

    final prefs = await _prefs();
    final a = _activity(prefs);
    if (chapters > 0) {
      final k = localDayKey();
      a.days[k] = (a.days[k] ?? 0) + chapters;
    }
    if (finishes > 0) {
      final k = localMonthKey();
      a.months[k] = (a.months[k] ?? 0) + finishes;
    }
    // Keep about a year and a half of days; months are tiny.
    if (a.days.length > 550) {
      final keys = a.days.keys.toList()..sort();
      for (final k in keys.take(a.days.length - 550)) {
        a.days.remove(k);
      }
    }
    await prefs.setString(
        _activityKey, jsonEncode({'days': a.days, 'months': a.months}));
  }

  /// Chapters read per local day for the last [days] days (oldest first).
  static Future<List<({DateTime day, int chapters})>> chaptersPerDay(
      {int days = 14}) async {
    final a = _activity(await _prefs());
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day - (days - 1));
    return List.generate(days, (i) {
      final d = DateTime(start.year, start.month, start.day + i);
      return (day: d, chapters: a.days[localDayKey(d)] ?? 0);
    });
  }

  /// Titles finished per month for the last [months] months (oldest first).
  static Future<List<({DateTime month, int count})>> completionsPerMonth(
      {int months = 6}) async {
    final a = _activity(await _prefs());
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - (months - 1), 1);
    return List.generate(months, (i) {
      final m = DateTime(start.year, start.month + i, 1);
      return (month: m, count: a.months[localMonthKey(m)] ?? 0);
    });
  }

  static ({Map<String, int> days, Map<String, int> months}) _activity(
      SharedPreferences prefs) {
    Map<String, int> read(Object? m) => {
          if (m is Map)
            for (final e in m.entries)
              if (e.value is num) '${e.key}': (e.value as num).toInt(),
        };
    try {
      final raw = prefs.getString(_activityKey);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map) return (days: read(j['days']), months: read(j['months']));
    } catch (_) {}
    return (days: <String, int>{}, months: <String, int>{});
  }

  // ---- One-time move from the account version ----

  /// Panel used to keep a copy of each account's list on the phone
  /// (`entries_cache_v1_<user id>`), including changes that hadn't synced.
  /// The first time this version runs, that copy becomes the local list, and
  /// the account's Updates tab moves over too.
  static Future<void> _migrate(SharedPreferences prefs) async {
    if (prefs.getBool(_migratedKey) == true) return;
    if (prefs.getString(_entriesKey) == null) {
      String? best;
      var bestCount = -1;
      String? bestUser;
      for (final k in prefs.getKeys()) {
        if (!k.startsWith('entries_cache_v1_')) continue;
        final raw = prefs.getString(k);
        final n = _decodeEntries(raw).length;
        if (n > bestCount) {
          best = raw;
          bestCount = n;
          bestUser = k.substring('entries_cache_v1_'.length);
        }
      }
      if (best != null && bestCount > 0) {
        await prefs.setString(_entriesKey, best);
        final inbox = prefs.getString('inbox_v1_$bestUser');
        if (inbox != null && prefs.getString('inbox_v2') == null) {
          await prefs.setString('inbox_v2', inbox);
        }
      }
    }
    await prefs.setBool(_migratedKey, true);
  }

  // ---- Decoding ----

  static List<Entry> _decodeEntries(String? raw) {
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final j in list)
          if (j is Map) Entry.fromJson(j.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, Map<String, dynamic>> _decodePatches(String? raw) {
    if (raw == null) return {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return {
        for (final e in j.entries)
          if (e.value is Map)
            '${e.key}': (e.value as Map).cast<String, dynamic>(),
      };
    } catch (_) {
      return {};
    }
  }
}

/// Random UUID v4 for new titles.
String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
