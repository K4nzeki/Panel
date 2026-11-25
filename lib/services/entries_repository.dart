import 'dart:convert';

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

  /// Saves [patch] and returns the row as stored. Also writes the activity
  /// logs that power the Stats tab (same rules as the web app).
  Future<Entry> update(Entry before, Map<String, dynamic> patch) async {
    final full = {...patch};
    if (patch.containsKey('chapter')) {
      full['last_read_at'] = DateTime.now().toUtc().toIso8601String();
    }
    final row = await _db
        .from('entries')
        .update(full)
        .eq('id', before.id)
        .eq('user_id', userId)
        .select(entryColumns)
        .maybeSingle();
    if (row == null) {
      throw const DataException(
          'No matching row was updated. Pull to refresh and try again.');
    }
    final after = Entry.fromJson(row);
    await _logActivity(before, after, patch);
    return after;
  }

  Future<void> _logActivity(
      Entry before, Entry after, Map<String, dynamic> patch) async {
    try {
      // A title moving *into* Finished counts as one completion this month.
      if (patch.containsKey('status') &&
          before.status != EntryStatus.finished &&
          after.status == EntryStatus.finished) {
        await _db.from('completion_log').insert({
          'user_id': userId,
          'entry_id': after.id,
          'title': after.title,
          'month': localMonthKey(),
        });
      }

      // Each extra reread is another completion.
      final rereadDelta =
          patch.containsKey('reread') ? after.reread - before.reread : 0;
      if (rereadDelta > 0) {
        await _db.from('completion_log').insert(List.generate(
            rereadDelta,
            (_) => {
                  'user_id': userId,
                  'entry_id': after.id,
                  'title': after.title,
                  'month': localMonthKey(),
                }));
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
          await _db.from('chapter_log').insert({
            'user_id': userId,
            'entry_id': after.id,
            'day': localDayKey(),
            'delta': delta,
          });
        }
      }
    } catch (_) {
      // Logs only feed the stats charts — never fail the user's save.
    }
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
  }
}

class DataException implements Exception {
  const DataException(this.message);
  final String message;
  @override
  String toString() => message;
}
