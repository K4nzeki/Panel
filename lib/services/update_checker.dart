import 'package:shared_preferences/shared_preferences.dart';

import '../models/entry.dart';
import 'anilist.dart';
import 'extension_covers.dart';
import 'mangadex.dart';

/// A series whose newest chapter went up during a check.
class SeriesUpdate {
  const SeriesUpdate(this.entry, this.latest);
  final Entry entry;
  final int latest;
  int get unread => latest - entry.chapter;
}

/// Saves a change to one entry (entry column names, e.g. `latest_chapter`).
/// The app applies it to its list; the background job saves it as a patch
/// for the app to pick up.
typedef PatchSaver = Future<void> Function(String id, Map<String, dynamic> patch);

/// Checks the titles you're reading for new chapters. Used by both the app
/// (when it opens and it's been 5 hours) and the background job. Works on
/// a list handed to it and reports changes through a [PatchSaver], so it
/// doesn't care where the list lives.
class UpdateChecker {
  UpdateChecker({MangaDexService? source}) : _source = source ?? MangaDexService();

  final MangaDexService _source;

  static const interval = Duration(hours: 5);

  static const _lastKey = 'updates_last_check_v2';

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

  /// Runs one check over [all]. Links unlinked titles first (exact title
  /// match only), then reads the newest chapter of each linked title.
  /// Returns the titles whose newest chapter went up since the last check
  /// and that you haven't read yet (these get a notification).
  ///
  /// Throws [UpdateOffline] if the connection drops before anything was
  /// checked; stops early (keeping what it saved) if it drops later.
  Future<List<SeriesUpdate>> run(List<Entry> all, PatchSaver save,
      {void Function(int done, int total)? onProgress}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);

    final entries = all
        .where((e) =>
            e.status == EntryStatus.reading &&
            e.type != EntryType.comic) // not on MangaDex
        .toList();

    final updates = <SeriesUpdate>[];
    var done = 0;
    var reached = false;
    onProgress?.call(0, entries.length);
    for (var e in entries) {
      onProgress?.call(done++, entries.length);
      try {
        if (e.sourceId == null) {
          e = await _link(e, save);
          await _pause();
        }
        final id = MangaDexService.idFrom(e.sourceId);
        if (id == null) continue;

        final latest = await _source.latestChapter(id);
        reached = true;
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
        await save(e.id, patch);
      } on MangaDexException catch (err) {
        reached = true;
        if (err.rateLimited) {
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        // Skip this title this round.
      } catch (_) {
        if (!reached) throw const UpdateOffline();
        break; // offline / timeout — try again next time
      }
    }
    return updates;
  }

  /// Finds the title on MangaDex. Saves the link (or [noSourceFound]) and
  /// fills in a missing cover.
  Future<Entry> _link(Entry e, PatchSaver save) async {
    final match = await _source.findExact(e.title);
    if (match == null) {
      await save(e.id, {'source_id': noSourceFound});
      return e.copyWith(sourceId: const Nullable(noSourceFound));
    }
    final patch = <String, dynamic>{'source_id': match.sourceId};
    final noCover = e.coverUrl == null || e.coverUrl!.trim().isEmpty;
    if (noCover && match.coverUrl != null) patch['cover_url'] = match.coverUrl;
    await save(e.id, patch);
    return e.copyWith(sourceId: Nullable(match.sourceId));
  }

  static const _noCoverKey = 'covers_not_found_v2';
  static const _noCoverSigKey = 'covers_not_found_sig_v2';

  /// Finds covers for titles in [all] that don't have one (AniList first,
  /// then MangaDex, then the sites of installed extensions), plus a missing
  /// author / chapter count. Titles no source has are remembered so they
  /// aren't searched every time (forgotten when extensions change). Stops
  /// quietly when offline. Used by the background job.
  Future<int> fillCovers(List<Entry> all, PatchSaver save, AniListService anilist,
      {int max = 80,
      ExtensionCoverFinder? extensions,
      void Function(int done, int total)? onProgress}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ext = extensions ?? ExtensionCoverFinder.empty;
    if (prefs.getString(_noCoverSigKey) != ext.signature) {
      await prefs.remove(_noCoverKey);
      await prefs.setString(_noCoverSigKey, ext.signature);
    }
    final skip = {...?prefs.getStringList(_noCoverKey)};
    final todo = all
        .where((e) =>
            (e.coverUrl == null || e.coverUrl!.trim().isEmpty) &&
            (e.type != EntryType.comic || ext.isNotEmpty) &&
            !skip.contains(normalizeTitle(e.title)))
        .take(max)
        .toList();

    var found = 0;
    var done = 0;
    for (final e in todo) {
      onProgress?.call(done++, todo.length);
      SearchResult? match;
      String? cover;
      var errored = false;
      try {
        if (e.type != EntryType.comic) {
          match = await anilist.lookup(e.title);
          cover = match?.coverUrl;
          if (cover == null || cover.isEmpty) {
            cover = (await _source.findExact(e.title))?.coverUrl;
          }
        }
      } on AniListException catch (err) {
        if (err.rateLimited) break; // try again next run
        errored = true; // fall through to the extensions
      } on MangaDexException {
        errored = true;
      } catch (_) {
        break; // offline
      }
      if ((cover == null || cover.isEmpty) && ext.isNotEmpty) {
        cover = await ext.find(e.title);
      }
      if (cover == null || cover.isEmpty) {
        // Only remember "not found" when every source actually answered.
        if (!errored) skip.add(normalizeTitle(e.title));
      } else {
        await save(e.id, {
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

  // Stay well under MangaDex's ~5 requests/second.
  Future<void> _pause() =>
      Future<void>.delayed(const Duration(milliseconds: 350));
}

/// The check couldn't reach anything (no connection).
class UpdateOffline implements Exception {
  const UpdateOffline();
  @override
  String toString() => "You're offline.";
}
