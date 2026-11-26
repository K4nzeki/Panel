import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entry.dart';
import 'anilist.dart';
import 'mangadex.dart';

/// A series whose newest chapter went up during a check.
class SeriesUpdate {
  const SeriesUpdate(this.entry, this.latest);
  final Entry entry;
  final int latest;
  int get unread => latest - entry.chapter;
}

/// Checks the titles you're reading for new chapters. Used by both the app
/// (when it opens and it's been 5 hours) and the background job, so it talks
/// to Supabase directly instead of going through the app's state.
class UpdateChecker {
  UpdateChecker(this._db, this.userId, {MangaDexService? source})
      : _source = source ?? MangaDexService();

  final SupabaseClient _db;
  final String userId;
  final MangaDexService _source;

  static const interval = Duration(hours: 5);

  String get _lastKey => 'updates_last_check_v1_$userId';

  Future<DateTime?> lastCheck() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // the other isolate may have written it
    final ms = prefs.getInt(_lastKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<bool> isDue() async {
    final last = await lastCheck();
    return last == null || DateTime.now().difference(last) >= interval;
  }

  /// Runs one check. Links unlinked titles first (exact title match only),
  /// then reads the newest chapter of each linked title. Returns the titles
  /// whose newest chapter went up since the last check and that you haven't
  /// read yet (these get a notification).
  ///
  /// Stops early and keeps what it saved if the connection drops.
  Future<List<SeriesUpdate>> run() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);

    final rows = await _db
        .from('entries')
        .select(entryColumns)
        .eq('user_id', userId)
        .eq('status', EntryStatus.reading.label);
    final entries = rows.map(Entry.fromJson).toList();

    final updates = <SeriesUpdate>[];
    for (var e in entries) {
      if (e.type == EntryType.comic) continue; // not on MangaDex
      try {
        if (e.sourceId == null) {
          e = await _link(e);
          await _pause();
        }
        final id = MangaDexService.idFrom(e.sourceId);
        if (id == null) continue;

        final latest = await _source.latestChapter(id);
        await _pause();
        final now = DateTime.now().toUtc().toIso8601String();
        final patch = <String, dynamic>{'latest_checked_at': now};
        if (latest != null && latest != e.latestChapter) {
          patch['latest_chapter'] = latest;
          // First check only records the number; later increases notify.
          final before = e.latestChapter;
          if (before != null && latest > before && latest > e.chapter) {
            updates.add(SeriesUpdate(e, latest));
          }
        }
        await _patch(e.id, patch);
      } on MangaDexException catch (err) {
        if (err.rateLimited) {
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        // Skip this title this round.
      } on PostgrestException {
        rethrow;
      } catch (_) {
        break; // offline / timeout — try again next time
      }
    }
    return updates;
  }

  /// Finds the title on MangaDex. Saves the link (or [noSourceFound]) and
  /// fills in a missing cover.
  Future<Entry> _link(Entry e) async {
    final match = await _source.findExact(e.title);
    if (match == null) {
      await _patch(e.id, {'source_id': noSourceFound});
      return e.copyWith(sourceId: const Nullable(noSourceFound));
    }
    final patch = <String, dynamic>{'source_id': match.sourceId};
    final noCover = e.coverUrl == null || e.coverUrl!.trim().isEmpty;
    if (noCover && match.coverUrl != null) patch['cover_url'] = match.coverUrl;
    await _patch(e.id, patch);
    return e.copyWith(sourceId: Nullable(match.sourceId));
  }

  String get _noCoverKey => 'covers_not_found_v1_$userId';

  /// Finds covers for titles that don't have one (AniList first, then
  /// MangaDex), plus a missing author / chapter count. Titles neither source
  /// has are remembered so they aren't searched every time. Stops quietly
  /// when offline. Used by the background job.
  Future<int> fillCovers(AniListService anilist, {int max = 80}) async {
    final prefs = await SharedPreferences.getInstance();
    final skip = {...?prefs.getStringList(_noCoverKey)};
    final rows = await _db
        .from('entries')
        .select(entryColumns)
        .eq('user_id', userId)
        .or('cover_url.is.null,cover_url.eq.');
    final todo = rows
        .map(Entry.fromJson)
        .where((e) =>
            e.type != EntryType.comic && !skip.contains(normalizeTitle(e.title)))
        .take(max)
        .toList();

    var found = 0;
    for (final e in todo) {
      SearchResult? match;
      String? cover;
      try {
        match = await anilist.lookup(e.title);
        cover = match?.coverUrl;
        if (cover == null || cover.isEmpty) {
          cover = (await _source.findExact(e.title))?.coverUrl;
        }
      } on AniListException catch (err) {
        if (err.rateLimited) break; // try again next run
        continue;
      } on MangaDexException {
        continue;
      } catch (_) {
        break; // offline
      }
      if (cover == null || cover.isEmpty) {
        skip.add(normalizeTitle(e.title));
      } else {
        await _patch(e.id, {
          'cover_url': cover,
          if (e.author == null && match?.author != null) 'author': match!.author,
          if (e.totalChapters == null && match?.totalChapters != null)
            'total_chapters': match!.totalChapters,
        });
        found++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    await prefs.setStringList(_noCoverKey, skip.toList());
    return found;
  }

  Future<void> _patch(String id, Map<String, dynamic> patch) =>
      _db.from('entries').update(patch).eq('id', id).eq('user_id', userId);

  // Stay well under MangaDex's ~5 requests/second.
  Future<void> _pause() =>
      Future<void>.delayed(const Duration(milliseconds: 350));
}
