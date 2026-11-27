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

  /// Columns only you (or the reader, when you finish a chapter) change.
  /// New-chapter checks may update the newest chapter, total, cover … but
  /// never these, so a chapter coming out can't count as one you've read.
  static const progressColumns = {
    'chapter',
    'reread',
    'chapters_banked',
    'reread_overlap',
    'status',
    'last_read_at',
  };

  /// [patch] without [progressColumns].
  static Map<String, dynamic> withoutProgress(Map<String, dynamic> patch) =>
      patch.keys.any(progressColumns.contains)
          ? {
              for (final e in patch.entries)
                if (!progressColumns.contains(e.key)) e.key: e.value,
            }
          : patch;

  /// Saves [patch] (entry columns, e.g. `latest_chapter`) for entry [id].
  /// Used only by the background isolate.
  static Future<void> addBackgroundPatch(
      String id, Map<String, dynamic> patch) async {
    patch = withoutProgress(patch);
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
        if (patches[e.id] case final p?)
          applyPatch(e, withoutProgress(p))
        else
          e,
    ];
  }

  /// [patch] uses the same column names as [Entry.toJson].
  static Entry applyPatch(Entry e, Map<String, dynamic> patch) =>
      Entry.fromJson({...e.toJson(), ...patch});

  // ---- Stats (chapters per day, finishes per month) ----

  /// Records what a change from [before] to [after] means for Stats: a move
  /// into Finished or an extra reread is one finish this month, and only
  /// chapters *read* count for today — the chapter number going up.
  ///
  /// Chapters logged per day are also remembered per title, so they can
  /// come off again:
  /// - the chapter number going down (fixing a mistake) takes that many
  ///   chapters back off the days they were logged on, newest first;
  /// - deleting the title takes all of its chapters off ([forgetEntry]).
  ///
  /// Adding a reread closes the current read-through: its chapters stay on
  /// Stats even when the chapter number is then cleared to start over.
  ///
  /// A new chapter coming out (newest chapter / total going up) never
  /// counts as reading.
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

    final chapters = chaptersReadDelta(before, after, patch);
    final unread = chaptersUnreadDelta(before, after, patch);
    if (finishes <= 0 && chapters <= 0 && unread <= 0 && rereadDelta <= 0) {
      return;
    }

    final prefs = await _prefs();
    final a = _activity(prefs);
    final log = a.entries.putIfAbsent(before.id, EntryLog.new);
    // A reread first, so clearing the count in the same change keeps the
    // finished read-through's chapters.
    if (rereadDelta > 0) log.closeReadThrough();
    if (unread > 0) {
      final removed = log.takeBack(unread);
      _subtract(a.days, removed);
    }
    if (chapters > 0) {
      final k = localDayKey();
      a.days[k] = (a.days[k] ?? 0) + chapters;
      log.current[k] = (log.current[k] ?? 0) + chapters;
    }
    if (finishes > 0) {
      final k = localMonthKey();
      a.months[k] = (a.months[k] ?? 0) + finishes;
    }
    if (log.isEmpty) a.entries.remove(before.id);
    _trim(a);
    await _writeActivity(prefs, a);
  }

  /// Chapters a change counts as read: how far the chapter number moved
  /// forward, 0 otherwise. Only the `chapter` column counts — never
  /// `latest_chapter` or `total_chapters`.
  static int chaptersReadDelta(
      Entry before, Entry after, Map<String, dynamic> patch) {
    if (!patch.containsKey('chapter')) return 0;
    final d = after.chapter - before.chapter;
    return d > 0 ? d : 0;
  }

  /// How far the chapter number moved back, 0 otherwise.
  static int chaptersUnreadDelta(
      Entry before, Entry after, Map<String, dynamic> patch) {
    if (!patch.containsKey('chapter')) return 0;
    final d = before.chapter - after.chapter;
    return d > 0 ? d : 0;
  }

  /// A title was deleted: takes every chapter logged for it off the daily
  /// counts. Returns what was removed so [restoreEntry] can put it back
  /// (Undo); null when nothing was logged for it.
  static Future<EntryLog?> forgetEntry(String entryId) async {
    final prefs = await _prefs();
    final a = _activity(prefs);
    final log = a.entries.remove(entryId);
    if (log == null) return null;
    _subtract(a.days, log.current);
    _subtract(a.days, log.earlier);
    await _writeActivity(prefs, a);
    return log;
  }

  /// Undo of [forgetEntry].
  static Future<void> restoreEntry(String entryId, EntryLog log) async {
    final prefs = await _prefs();
    final a = _activity(prefs);
    if (a.entries.containsKey(entryId)) return;
    a.entries[entryId] = log;
    for (final m in [log.current, log.earlier]) {
      for (final e in m.entries) {
        a.days[e.key] = (a.days[e.key] ?? 0) + e.value;
      }
    }
    await _writeActivity(prefs, a);
  }

  static void _subtract(Map<String, int> days, Map<String, int> by) {
    for (final e in by.entries) {
      final left = (days[e.key] ?? 0) - e.value;
      if (left > 0) {
        days[e.key] = left;
      } else {
        days.remove(e.key);
      }
    }
  }

  /// Keeps about a year and a half of days; months are tiny.
  static void _trim(_Activity a) {
    if (a.days.length <= 550) return;
    final keys = a.days.keys.toList()..sort();
    final cutoff = keys[a.days.length - 550];
    for (final k in keys.take(a.days.length - 550)) {
      a.days.remove(k);
    }
    for (final log in a.entries.values) {
      log.current.removeWhere((k, _) => k.compareTo(cutoff) < 0);
      log.earlier.removeWhere((k, _) => k.compareTo(cutoff) < 0);
    }
    a.entries.removeWhere((_, log) => log.isEmpty);
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

  static _Activity _activity(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_activityKey);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map) {
        final entries = j['entries'];
        return (
          days: _intMap(j['days']),
          months: _intMap(j['months']),
          entries: {
            if (entries is Map)
              for (final e in entries.entries)
                '${e.key}': EntryLog.fromJson(e.value),
          },
        );
      }
    } catch (_) {}
    return (
      days: <String, int>{},
      months: <String, int>{},
      entries: <String, EntryLog>{},
    );
  }

  static Future<void> _writeActivity(
          SharedPreferences prefs, _Activity a) =>
      prefs.setString(
          _activityKey,
          jsonEncode({
            'days': a.days,
            'months': a.months,
            'entries': {
              for (final e in a.entries.entries) e.key: e.value.toJson(),
            },
          }));

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

typedef _Activity = ({
  Map<String, int> days,
  Map<String, int> months,
  Map<String, EntryLog> entries,
});

Map<String, int> _intMap(Object? m) => {
      if (m is Map)
        for (final e in m.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };

/// The chapters one title added to the daily counts, by local day.
class EntryLog {
  EntryLog({Map<String, int>? current, Map<String, int>? earlier})
      : current = current ?? {},
        earlier = earlier ?? {};

  factory EntryLog.fromJson(Object? j) => j is Map
      ? EntryLog(current: _intMap(j['cur']), earlier: _intMap(j['old']))
      : EntryLog();

  /// This read-through: lowering the chapter number takes from here.
  final Map<String, int> current;

  /// Finished read-throughs (before a reread was added): only deleting the
  /// title takes these off.
  final Map<String, int> earlier;

  bool get isEmpty => current.isEmpty && earlier.isEmpty;

  /// A reread was added: this read-through is done and stays counted.
  void closeReadThrough() {
    for (final e in current.entries) {
      earlier[e.key] = (earlier[e.key] ?? 0) + e.value;
    }
    current.clear();
  }

  /// Takes up to [n] chapters back off this read-through, newest days
  /// first. Returns what was taken, by day.
  Map<String, int> takeBack(int n) {
    final taken = <String, int>{};
    final keys = current.keys.toList()..sort();
    for (final k in keys.reversed) {
      if (n <= 0) break;
      final have = current[k]!;
      final t = have < n ? have : n;
      taken[k] = t;
      n -= t;
      if (have - t > 0) {
        current[k] = have - t;
      } else {
        current.remove(k);
      }
    }
    return taken;
  }

  Map<String, dynamic> toJson() => {'cur': current, 'old': earlier};
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
