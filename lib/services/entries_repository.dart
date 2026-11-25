import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entry.dart';
import '../utils/dates.dart';

/// All Supabase reads/writes for a signed-in reader's list. Every query is
/// scoped by `user_id` as well as protected by RLS on the server.
class EntriesRepository {
  EntriesRepository(this._db, this.userId);

  final SupabaseClient _db;
  final String userId;

  String get _cacheKey => 'entries_cache_v1_$userId';

  Future<List<Entry>> fetchAll() async {
    final rows = await _db
        .from('entries')
        .select(entryColumns)
        .eq('user_id', userId)
        .order('position', ascending: true);
    return rows.map(Entry.fromJson).toList();
  }

  Future<Entry> insert({
    required String title,
    required EntryType type,
    required EntryStatus status,
    required int position,
    int chapter = 0,
    int reread = 0,
    String? coverUrl,
    String? author,
    int? totalChapters,
    String? readOnUrl,
  }) async {
    final row = await _db
        .from('entries')
        .insert({
          'user_id': userId,
          'title': title,
          'type': type.label,
          'status': status.label,
          'chapter': chapter,
          'reread': reread,
          'position': position,
          'cover_url': coverUrl,
          'author': author,
          'total_chapters': totalChapters,
          'read_on_url': readOnUrl,
        })
        .select(entryColumns)
        .single();
    return Entry.fromJson(row);
  }

  Future<List<Entry>> insertMany(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return const [];
    final withUser = rows.map((r) => {...r, 'user_id': userId}).toList();
    final data =
        await _db.from('entries').insert(withUser).select(entryColumns);
    return data.map(Entry.fromJson).toList();
  }

  /// The activity-log rows (for the Stats tab) that a change from [before]
  /// to [after] produces. Built at the moment of the change so offline edits
  /// are counted on the right day once they sync.
  List<({String table, Map<String, dynamic> row})> activityRows(
      Entry before, Entry after, Map<String, dynamic> patch) {
    final out = <({String table, Map<String, dynamic> row})>[];
    Map<String, dynamic> completion() => {
          'user_id': userId,
          'entry_id': after.id,
          'title': after.title,
          'month': localMonthKey(),
        };

    // A title moving *into* Finished counts as one completion this month.
    if (patch.containsKey('status') &&
        before.status != EntryStatus.finished &&
        after.status == EntryStatus.finished) {
      out.add((table: 'completion_log', row: completion()));
    }

    // Each extra reread is another completion.
    final rereadDelta =
        patch.containsKey('reread') ? after.reread - before.reread : 0;
    for (var i = 0; i < rereadDelta; i++) {
      out.add((table: 'completion_log', row: completion()));
    }

    // Chapters read today. Going down means a restart (reread), so the
    // new chapter number counts as read; never logs a negative number.
    if (patch.containsKey('chapter') &&
        after.chapter != before.chapter &&
        !(rereadDelta > 0 && after.chapter < before.chapter)) {
      final delta = after.chapter > before.chapter
          ? after.chapter - before.chapter
          : after.chapter;
      if (delta > 0) {
        out.add((
          table: 'chapter_log',
          row: {
            'user_id': userId,
            'entry_id': after.id,
            'day': localDayKey(),
            'delta': delta,
          }
        ));
      }
    }
    return out;
  }

  // ---- Raw writes used by the offline sync queue ----

  Future<void> upsertRow(Map<String, dynamic> row) async {
    await _db.from('entries').upsert({...row, 'user_id': userId},
        onConflict: 'id');
  }

  Future<void> patchRow(String id, Map<String, dynamic> patch) async {
    await _db.from('entries').update(patch).eq('id', id).eq('user_id', userId);
  }

  Future<void> deleteRow(String id) async {
    await _db.from('entries').delete().eq('id', id).eq('user_id', userId);
  }

  Future<void> insertLog(String table, Map<String, dynamic> row) async {
    await _db.from(table).insert({...row, 'user_id': userId});
  }

  Future<void> delete(String id) async {
    final row = await _db
        .from('entries')
        .delete()
        .eq('id', id)
        .eq('user_id', userId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      throw const DataException('No matching row was deleted.');
    }
  }

  Future<void> setPositions(Map<String, int> positions) async {
    await Future.wait(positions.entries.map((e) => _db
        .from('entries')
        .update({'position': e.value})
        .eq('id', e.key)
        .eq('user_id', userId)));
  }

  // ---- Stats ----

  /// Chapters read per local day for the last [days] days (oldest first).
  Future<List<({DateTime day, int chapters})>> chaptersPerDay(
      {int days = 14}) async {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day - (days - 1));
    final rows = await _db
        .from('chapter_log')
        .select('day, delta')
        .eq('user_id', userId)
        .gte('day', localDayKey(start));
    final totals = <String, int>{};
    for (final r in rows) {
      final key = r['day'].toString().substring(0, 10);
      totals[key] = (totals[key] ?? 0) + ((r['delta'] as num?)?.toInt() ?? 0);
    }
    return List.generate(days, (i) {
      final d = DateTime(start.year, start.month, start.day + i);
      return (day: d, chapters: totals[localDayKey(d)] ?? 0);
    });
  }

  /// Titles finished per month for the last [months] months (oldest first).
  Future<List<({DateTime month, int count})>> completionsPerMonth(
      {int months = 6}) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - (months - 1), 1);
    final rows = await _db
        .from('completion_log')
        .select('month')
        .eq('user_id', userId)
        .gte('month', localMonthKey(start));
    final totals = <String, int>{};
    for (final r in rows) {
      final key = '${r['month'].toString().substring(0, 7)}-01';
      totals[key] = (totals[key] ?? 0) + 1;
    }
    return List.generate(months, (i) {
      final m = DateTime(start.year, start.month + i, 1);
      return (month: m, count: totals[localMonthKey(m)] ?? 0);
    });
  }

  // ---- Offline cache (instant startup, works without signal) ----

  Future<List<Entry>?> readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(Entry.fromJson).toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCache(List<Entry> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _cacheKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_outboxKey);
  }

  // ---- Outbox: changes made offline, waiting to be sent ----

  String get _outboxKey => 'outbox_v1_$userId';

  Future<List<Map<String, dynamic>>> readOutbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_outboxKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> writeOutbox(List<Map<String, dynamic>> ops) async {
    final prefs = await SharedPreferences.getInstance();
    if (ops.isEmpty) {
      await prefs.remove(_outboxKey);
    } else {
      await prefs.setString(_outboxKey, jsonEncode(ops));
    }
  }
}

/// Random UUID v4, so titles added offline already have their final id.
String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

class DataException implements Exception {
  const DataException(this.message);
  final String message;
  @override
  String toString() => message;
}
