import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entry.dart';
import '../services/anilist.dart';
import '../services/background.dart';
import '../services/entries_repository.dart';
import '../services/mangadex.dart';
import '../services/update_checker.dart';
import '../utils/import_merge.dart';

// ---------------------------------------------------------------------------
// Core services
// ---------------------------------------------------------------------------

final supabaseProvider =
    Provider<SupabaseClient>((ref) => Supabase.instance.client);

final aniListProvider = Provider<AniListService>((ref) => AniListService());

final mangaDexProvider = Provider<MangaDexService>((ref) => MangaDexService());

/// True while a new-chapter check is running in the app.
final updateCheckingProvider = StateProvider<bool>((ref) => false);

final authStateProvider = StreamProvider<AuthState>(
    (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange);

/// The signed-in user's id. Only changes on sign-in / sign-out (not on token
/// refreshes), so everything that depends on it doesn't reload needlessly.
final userIdProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser?.id;
});

final userEmailProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser?.email;
});

/// Set when the user opens a password-reset link from their email.
final passwordRecoveryProvider = StateProvider<bool>((ref) => false);

final repositoryProvider = Provider<EntriesRepository?>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return null;
  return EntriesRepository(ref.watch(supabaseProvider), uid);
});

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    unawaited(_load());
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final i = prefs.getInt(_key);
    if (i != null && i >= 0 && i < ThemeMode.values.length) {
      state = ThemeMode.values[i];
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, mode.index);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

// ---------------------------------------------------------------------------
// The reader's list
// ---------------------------------------------------------------------------

/// Non-null while the last sync with Supabase failed for a reason other
/// than being offline (shown as a banner).
final syncErrorProvider = StateProvider<String?>((ref) => null);

/// False while the server can't be reached. Changes keep working locally.
final onlineProvider = StateProvider<bool>((ref) => true);

/// Ids of titles with changes that haven't reached the server yet.
final pendingIdsProvider = StateProvider<Set<String>>((ref) => const {});

/// How many changes are waiting to sync.
final pendingCountProvider = StateProvider<int>((ref) => 0);

/// Progress of the background "find missing covers" job, or null when idle.
final coverFillProvider =
    StateProvider<({int done, int total})?>((ref) => null);

/// Offline-first list. Every change is applied on the phone straight away,
/// saved to a local queue (the "outbox"), and sent to Supabase whenever
/// there's a connection — on launch, when the app comes back to the
/// foreground, every 20 seconds while something is waiting, and on
/// pull-to-refresh.
class EntriesNotifier extends AsyncNotifier<List<Entry>> {
  EntriesRepository get _repo => ref.read(repositoryProvider)!;

  List<Entry> get _current => state.value ?? const [];

  List<Map<String, dynamic>> _outbox = [];
  bool _syncing = false;
  bool _syncAgain = false;
  Map<String, dynamic>? _inFlight; // op currently being sent
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  @override
  Future<List<Entry>> build() async {
    final repo = ref.watch(repositoryProvider);
    _timer?.cancel();
    _lifecycle?.dispose();
    ref.onDispose(() {
      _timer?.cancel();
      _lifecycle?.dispose();
    });
    if (repo == null) {
      _outbox = [];
      return const [];
    }

    _outbox = await repo.readOutbox();
    _publishPending();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_outbox.isNotEmpty) unawaited(sync());
    });
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));

    final cached = await repo.readCache();
    if (cached != null) {
      // Show the saved list instantly (works offline), then sync.
      Future.microtask(refresh);
      return cached;
    }
    final fresh = await repo.fetchAll();
    unawaited(repo.writeCache(fresh));
    _setOnline(true);
    return fresh;
  }

  // ---- local state ----

  void _set(List<Entry> list) {
    state = AsyncData(list);
    final repo = ref.read(repositoryProvider);
    if (repo != null) unawaited(repo.writeCache(list));
  }

  void _setOnline(bool v) {
    if (ref.read(onlineProvider) != v) {
      ref.read(onlineProvider.notifier).state = v;
    }
  }

  void _publishPending() {
    final ids = <String>{
      for (final op in _outbox)
        if (op['id'] != null) op['id'] as String,
    };
    ref.read(pendingIdsProvider.notifier).state = ids;
    ref.read(pendingCountProvider.notifier).state = _outbox.length;
  }

  Future<void> _persistOutbox() async {
    _publishPending();
    final repo = ref.read(repositoryProvider);
    if (repo != null) await repo.writeOutbox(_outbox);
  }

  /// Adds an operation to the queue, merging with earlier ones where it can
  /// (e.g. edits to a title that hasn't been uploaded yet just change the
  /// pending upload).
  void _enqueue(Map<String, dynamic> op) {
    final id = op['id'] as String?;
    switch (op['op']) {
      case 'update':
        final i = _outbox.lastIndexWhere(
            (o) => o['id'] == id && (o['op'] == 'upsert' || o['op'] == 'update'));
        // Only merge into the latest op for this id if nothing else for it
        // (like a log row) was queued after it.
        // (Never touch the op that is being uploaded right now.)
        if (i >= 0 &&
            !identical(_outbox[i], _inFlight) &&
            !_outbox.skip(i + 1).any((o) => o['id'] == id)) {
          final target = _outbox[i];
          final key = target['op'] == 'upsert' ? 'row' : 'patch';
          target[key] = {
            ...(target[key] as Map).cast<String, dynamic>(),
            ...(op['patch'] as Map).cast<String, dynamic>(),
          };
          return;
        }
      case 'delete':
        final uploading = _inFlight != null && _inFlight!['id'] == id;
        final neverUploaded = _outbox.any((o) =>
            o['id'] == id && o['op'] == 'upsert' && !identical(o, _inFlight));
        _outbox.removeWhere((o) =>
            o['id'] == id && o['op'] != 'delete' && !identical(o, _inFlight));
        // Never reached the server: nothing to delete there.
        if (neverUploaded && !uploading) return;
    }
    _outbox.add(op);
  }

  Future<void> _queue(List<Map<String, dynamic>> ops) async {
    for (final op in ops) {
      _enqueue(op);
    }
    await _persistOutbox();
    unawaited(sync());
  }

  // ---- syncing ----

  static bool _isConnectionProblem(Object e) {
    if (e is PostgrestException) {
      // Expired / missing login token: wait for the session to refresh.
      return e.code == 'PGRST301' ||
          e.code == 'PGRST303' ||
          e.message.toLowerCase().contains('jwt');
    }
    return true; // socket errors, timeouts, auth refresh failures, etc.
  }

  /// Sends queued changes to Supabase. Stops (and keeps the rest) at the
  /// first connection problem; a change the server rejects is dropped so it
  /// can't block everything behind it.
  Future<void> sync() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    final repo = ref.read(repositoryProvider);
    if (repo == null || _outbox.isEmpty) return;
    _syncing = true;
    try {
      while (_outbox.isNotEmpty) {
        final op = _outbox.first;
        _inFlight = op;
        try {
          switch (op['op']) {
            case 'upsert':
              await repo.upsertRow((op['row'] as Map).cast<String, dynamic>());
            case 'update':
              await repo.patchRow(
                  op['id'] as String, (op['patch'] as Map).cast<String, dynamic>());
            case 'delete':
              await repo.deleteRow(op['id'] as String);
            case 'log':
              await repo.insertLog(
                  op['table'] as String, (op['row'] as Map).cast<String, dynamic>());
          }
        } catch (e) {
          if (_isConnectionProblem(e)) {
            _inFlight = null;
            _setOnline(false);
            return;
          }
          // Log rows only feed the charts; never surface those failures.
          if (op['op'] != 'log') {
            ref.read(syncErrorProvider.notifier).state =
                "A change couldn't be saved: ${friendlyError(e)}";
          }
        }
        _inFlight = null;
        _outbox.remove(op);
        await _persistOutbox();
        _setOnline(true);
      }
    } finally {
      _syncing = false;
      if (_syncAgain) {
        _syncAgain = false;
        unawaited(sync());
      }
    }
  }

  /// Pushes pending changes, pulls the latest list from the server, then
  /// looks up covers for any titles that don't have one yet and checks for
  /// new chapters. Both run in the background after the list is shown;
  /// [manual] (pull-to-refresh) checks chapters now instead of every 5 hours.
  Future<void> refresh({bool manual = false}) async {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    await sync();
    // Don't overwrite local changes that haven't been uploaded yet.
    if (_outbox.isEmpty) {
      try {
        final fresh = await repo.fetchAll();
        if (_outbox.isEmpty) {
          _set(fresh);
          _setOnline(true);
        }
      } catch (e) {
        if (_isConnectionProblem(e)) {
          _setOnline(false);
        } else {
          ref.read(syncErrorProvider.notifier).state = friendlyError(e);
        }
        if (!state.hasValue) state = AsyncError(e, StackTrace.current);
      }
    }
    if (ref.read(onlineProvider)) {
      unawaited(fillMissingCovers());
      unawaited(checkUpdates(force: manual));
    }
  }

  // ---- new chapters ----

  bool _checking = false;

  /// Checks titles you're reading for new chapters — at most every 5 hours
  /// unless [force] is set. The background job does the same while the app
  /// is closed; whichever runs first resets the 5-hour clock.
  Future<void> checkUpdates({bool force = false}) async {
    final uid = ref.read(userIdProvider);
    if (uid == null || _checking) return;
    final checker = UpdateChecker(ref.read(supabaseProvider), uid,
        source: ref.read(mangaDexProvider));
    if (!force && !await checker.isDue()) return;
    _checking = true;
    ref.read(updateCheckingProvider.notifier).state = true;
    try {
      final updates = await checker.run();
      await Notifications.showUpdates(updates);
      await _pullSourceFields();
    } catch (_) {
      // Offline or the server refused — the next check will try again.
    } finally {
      _checking = false;
      ref.read(updateCheckingProvider.notifier).state = false;
    }
  }

  /// Copies what the update check saved on the server (links, newest
  /// chapter, covers it filled in) into the local list, without touching
  /// edits that haven't synced yet.
  Future<void> _pullSourceFields() async {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    final fresh = {for (final e in await repo.fetchAll()) e.id: e};
    _set([
      for (final e in _current)
        if (fresh[e.id] case final f?)
          e.copyWith(
            sourceId: Nullable(f.sourceId),
            latestChapter: Nullable(f.latestChapter),
            latestCheckedAt: Nullable(f.latestCheckedAt),
            coverUrl: (e.coverUrl == null || e.coverUrl!.trim().isEmpty)
                ? Nullable(f.coverUrl)
                : null,
          )
        else
          e,
    ]);
  }

  /// Links [e] to a series picked by hand. Uses its cover (the accurate one
  /// from the source) unless [keepCover] is set, and reads its newest chapter.
  Future<void> linkSource(Entry e, SourceManga m, {bool keepCover = false}) async {
    int? latest;
    try {
      latest = await ref.read(mangaDexProvider).latestChapter(m.id);
    } catch (_) {}
    final now = DateTime.now();
    final patch = <String, dynamic>{
      'source_id': m.sourceId,
      'latest_chapter': latest,
      'latest_checked_at': now.toUtc().toIso8601String(),
      if (!keepCover && m.coverUrl != null) 'cover_url': m.coverUrl,
    };
    await save(
      e,
      e.copyWith(
        sourceId: Nullable(m.sourceId),
        latestChapter: Nullable(latest),
        latestCheckedAt: Nullable(now),
        coverUrl: (!keepCover && m.coverUrl != null) ? Nullable(m.coverUrl) : null,
      ),
      patch,
    );
  }

  /// Stops checking [e] (and stops the background job linking it again).
  Future<void> unlinkSource(Entry e) => save(
        e,
        e.copyWith(
          sourceId: const Nullable(noSourceFound),
          latestChapter: const Nullable(null),
        ),
        {'source_id': noSourceFound, 'latest_chapter': null},
      );

  /// Re-reads the newest chapter of one linked title right now.
  Future<void> refreshLatest(Entry e) async {
    final id = MangaDexService.idFrom(e.sourceId);
    if (id == null) return;
    final latest = await ref.read(mangaDexProvider).latestChapter(id);
    final now = DateTime.now();
    await save(
      e,
      e.copyWith(latestChapter: Nullable(latest), latestCheckedAt: Nullable(now)),
      {
        'latest_chapter': latest,
        'latest_checked_at': now.toUtc().toIso8601String(),
      },
    );
  }

  void clearSyncError() => ref.read(syncErrorProvider.notifier).state = null;

  // ---- changes ----

  int _topPosition() {
    final list = _current;
    if (list.isEmpty) return 0;
    return list.map((e) => e.position).reduce((a, b) => a < b ? a : b) - 1;
  }

  Map<String, dynamic> _rowFor(Entry e) => {
        'id': e.id,
        'title': e.title,
        'type': e.type.label,
        'status': e.status.label,
        'chapter': e.chapter,
        'reread': e.reread,
        'position': e.position,
        'cover_url': e.coverUrl,
        'author': e.author,
        'total_chapters': e.totalChapters,
        'read_on_url': e.readOnUrl,
        'created_at': e.createdAt?.toUtc().toIso8601String(),
      };

  Future<Entry> add({
    required String title,
    required EntryType type,
    required EntryStatus status,
    int chapter = 0,
    String? coverUrl,
    String? author,
    int? totalChapters,
    String? readOnUrl,
  }) async {
    final entry = Entry(
      id: newUuid(),
      title: title,
      type: type,
      status: status,
      chapter: chapter,
      position: _topPosition(),
      createdAt: DateTime.now(),
      coverUrl: coverUrl,
      author: author,
      totalChapters: totalChapters,
      readOnUrl: readOnUrl,
    );
    _set([entry, ..._current]);
    await _queue([
      {'op': 'upsert', 'id': entry.id, 'row': _rowFor(entry)}
    ]);
    return entry;
  }

  /// Whether a title with this name is already in the list.
  Entry? findByTitle(String title) {
    final t = title.trim().toLowerCase();
    for (final e in _current) {
      if (e.title.trim().toLowerCase() == t) return e;
    }
    return null;
  }

  /// Applies [optimistic] locally right away and queues [patch] for upload.
  Future<void> save(Entry before, Entry optimistic,
      Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    final full = {...patch};
    var after = optimistic;
    if (patch.containsKey('chapter')) {
      final now = DateTime.now();
      full['last_read_at'] = now.toUtc().toIso8601String();
      after = after.copyWith(lastReadAt: now);
    }
    _set([
      for (final e in _current) e.id == before.id ? after : e,
    ]);
    if (before.status != EntryStatus.finished &&
        after.status == EntryStatus.finished) {
      unawaited(HapticFeedback.mediumImpact());
    }
    await _queue([
      {'op': 'update', 'id': before.id, 'patch': full},
      for (final log in _repo.activityRows(before, after, patch))
        {'op': 'log', 'id': before.id, 'table': log.table, 'row': log.row},
    ]);
  }

  Future<void> bumpChapter(Entry e, int by) async {
    final raw = e.chapter + by;
    final next = raw < 0 ? 0 : raw;
    if (next == e.chapter) return;
    unawaited(HapticFeedback.selectionClick());
    final patch = <String, dynamic>{'chapter': next};
    var optimistic = e.copyWith(chapter: next, lastReadAt: DateTime.now());
    // Reading the first chapter of something on the To Read pile moves it
    // into the library automatically.
    if (by > 0 && e.status == EntryStatus.toRead) {
      patch['status'] = EntryStatus.reading.label;
      optimistic = optimistic.copyWith(status: EntryStatus.reading);
    }
    await save(e, optimistic, patch);
  }

  Future<void> setStatus(Entry e, EntryStatus status) async {
    if (status == e.status) return;
    final patch = <String, dynamic>{'status': status.label};
    var optimistic = e.copyWith(status: status);
    // Finishing a title with a known length jumps progress to the end.
    final total = e.totalChapters;
    if (status == EntryStatus.finished && total != null && e.chapter < total) {
      patch['chapter'] = total;
      optimistic = optimistic.copyWith(chapter: total);
    }
    await save(e, optimistic, patch);
  }

  /// Deletes [e] and returns it so the caller can offer "Undo".
  Future<Entry> remove(Entry e) async {
    _set(_current.where((x) => x.id != e.id).toList());
    unawaited(HapticFeedback.lightImpact());
    await _queue([
      {'op': 'delete', 'id': e.id}
    ]);
    return e;
  }

  /// Puts a deleted entry back (gets a new id; keeps everything else).
  Future<void> restore(Entry e) async {
    final restored = Entry(
      id: newUuid(),
      title: e.title,
      type: e.type,
      status: e.status,
      chapter: e.chapter,
      reread: e.reread,
      position: e.position,
      createdAt: e.createdAt ?? DateTime.now(),
      coverUrl: e.coverUrl,
      author: e.author,
      totalChapters: e.totalChapters,
      readOnUrl: e.readOnUrl,
      lastReadAt: e.lastReadAt,
      sourceId: e.sourceId,
      latestChapter: e.latestChapter,
      latestCheckedAt: e.latestCheckedAt,
    );
    final list = [..._current, restored]
      ..sort((a, b) => a.position.compareTo(b.position));
    _set(list);
    await _queue([
      {
        'op': 'upsert',
        'id': restored.id,
        'row': {
          ..._rowFor(restored),
          'last_read_at': restored.lastReadAt?.toUtc().toIso8601String(),
          'source_id': restored.sourceId,
          'latest_chapter': restored.latestChapter,
          'latest_checked_at':
              restored.latestCheckedAt?.toUtc().toIso8601String(),
        }
      }
    ]);
  }

  /// Moves [moved] to sit where [target] is, in the custom ("My order") sort.
  Future<void> reorder(String movedId, String targetId) async {
    if (movedId == targetId) return;
    final ordered = [..._current]
      ..sort((a, b) => a.position.compareTo(b.position));
    final from = ordered.indexWhere((e) => e.id == movedId);
    final to = ordered.indexWhere((e) => e.id == targetId);
    if (from < 0 || to < 0) return;
    final moved = ordered.removeAt(from);
    ordered.insert(to, moved);

    final changed = <String, int>{};
    final next = <Entry>[];
    for (var i = 0; i < ordered.length; i++) {
      final e = ordered[i];
      if (e.position != i) changed[e.id] = i;
      next.add(e.position == i ? e : e.copyWith(position: i));
    }
    if (changed.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    _set(next);
    await _queue([
      for (final c in changed.entries)
        {'op': 'update', 'id': c.key, 'patch': {'position': c.value}},
    ]);
  }

  /// Bulk import from a pasted list or an Excel / CSV file. Uses an
  /// [ImportPlan] (see [planImport]) so the same title is never added twice:
  /// new titles are added, titles where the import has more chapters are
  /// moved forward to that chapter, everything else is left alone.
  ///
  /// Covers are looked up afterwards in the background (same as refresh).
  Future<({int added, int updated})> applyImport(ImportPlan plan) async {
    if (plan.isEmpty) return (added: 0, updated: 0);
    var top = _topPosition();
    final now = DateTime.now();

    // Keep the file's order: first row ends up at the top of "My order".
    final added = <Entry>[
      for (final p in plan.toAdd.reversed)
        Entry(
          id: newUuid(),
          title: p.title,
          type: p.type,
          status: p.status,
          chapter: p.chapter,
          reread: p.reread,
          position: top--,
          createdAt: now,
        ),
    ].reversed.toList();

    final updates = <String, ({Entry after, Map<String, dynamic> patch})>{};
    for (final u in plan.toUpdate) {
      final e = u.existing;
      final p = u.incoming;
      final reread = p.reread > e.reread ? p.reread : e.reread;
      final patch = <String, dynamic>{
        'chapter': p.chapter,
        'last_read_at': now.toUtc().toIso8601String(),
        if (p.status != e.status) 'status': p.status.label,
        if (reread != e.reread) 'reread': reread,
      };
      updates[e.id] = (
        after: e.copyWith(
          chapter: p.chapter,
          status: p.status,
          reread: reread,
          lastReadAt: now,
        ),
        patch: patch,
      );
    }

    final list = [
      ...added,
      for (final e in _current) updates[e.id]?.after ?? e,
    ]..sort((a, b) => a.position.compareTo(b.position));
    _set(list);
    // No chapter / completion log rows here: catching up an old list
    // shouldn't show up as hundreds of chapters "read today" in Stats.
    await _queue([
      for (final e in added) {'op': 'upsert', 'id': e.id, 'row': _rowFor(e)},
      for (final u in updates.entries)
        {'op': 'update', 'id': u.key, 'patch': u.value.patch},
    ]);
    unawaited(fillMissingCovers());
    return (added: added.length, updated: updates.length);
  }

  bool _filling = false;
  bool _fillAgain = false;

  /// Titles already looked up this session that AniList had no cover for,
  /// so every refresh doesn't search for them again.
  final Set<String> _noCoverFound = {};

  /// Looks up covers (plus author / chapter count if missing) on AniList
  /// for titles that don't have a cover yet. Runs one title at a time in
  /// the background, saves each as it's found, and stops quietly when
  /// offline. Comics are skipped (AniList barely has any).
  Future<void> fillMissingCovers() async {
    if (_filling) {
      _fillAgain = true;
      return;
    }
    bool needsCover(Entry e) =>
        (e.coverUrl == null || e.coverUrl!.trim().isEmpty) &&
        e.type != EntryType.comic &&
        !_noCoverFound.contains(titleKey(e.title));

    final todo = _current.where(needsCover).map((e) => e.id).toList();
    if (todo.isEmpty) return;
    _filling = true;
    final progress = ref.read(coverFillProvider.notifier);
    progress.state = (done: 0, total: todo.length);
    final anilist = ref.read(aniListProvider);
    try {
      var busyRetries = 0;
      for (var i = 0; i < todo.length; i++) {
        if (ref.read(repositoryProvider) == null) return; // signed out
        // Re-read: the title may have been edited or deleted meanwhile.
        final e = _current.where((x) => x.id == todo[i]).firstOrNull;
        if (e != null && needsCover(e)) {
          SearchResult? match;
          try {
            match = await anilist.lookup(e.title);
            busyRetries = 0;
          } on AniListException catch (err) {
            if (err.rateLimited && busyRetries < 2) {
              busyRetries++;
              await Future<void>.delayed(const Duration(seconds: 30));
              i--; // try this title again
              continue;
            }
            return; // AniList keeps refusing — try again next refresh
          } catch (_) {
            return; // offline — try again next refresh
          }
          var cover = match?.coverUrl;
          if (cover == null || cover.isEmpty) {
            // Not on AniList (or no cover there): try MangaDex.
            try {
              cover = (await ref.read(mangaDexProvider).findExact(e.title))
                  ?.coverUrl;
            } catch (_) {}
          }
          // Look it up again in case it changed during the request.
          final now = _current.where((x) => x.id == e.id).firstOrNull;
          if (cover == null || cover.isEmpty) {
            _noCoverFound.add(titleKey(e.title));
          } else if (now != null && needsCover(now)) {
            final patch = <String, dynamic>{'cover_url': cover};
            var after = now.copyWith(coverUrl: Nullable(cover));
            if (now.author == null && match!.author != null) {
              patch['author'] = match.author;
              after = after.copyWith(author: Nullable(match.author));
            }
            if (now.totalChapters == null && match!.totalChapters != null) {
              patch['total_chapters'] = match.totalChapters;
              after = after.copyWith(totalChapters: Nullable(match.totalChapters));
            }
            _set([for (final x in _current) x.id == now.id ? after : x]);
            await _queue([
              {'op': 'update', 'id': now.id, 'patch': patch}
            ]);
          }
          // Stay well under AniList's rate limit.
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
        progress.state = (done: i + 1, total: todo.length);
      }
    } finally {
      _filling = false;
      progress.state = null;
      if (_fillAgain) {
        _fillAgain = false;
        unawaited(fillMissingCovers());
      }
    }
  }
}

final entriesProvider =
    AsyncNotifierProvider<EntriesNotifier, List<Entry>>(EntriesNotifier.new);

// ---------------------------------------------------------------------------
// Library filters & sorting (one set per tab)
// ---------------------------------------------------------------------------

enum ListTab { library, toRead }

enum SortOption {
  recent('Recent activity', Icons.history_rounded),
  added('Recently added', Icons.schedule_rounded),
  title('Title A–Z', Icons.sort_by_alpha_rounded),
  progress('Most chapters', Icons.trending_up_rounded),
  custom('My order', Icons.drag_indicator_rounded);

  const SortOption(this.label, this.icon);
  final String label;
  final IconData icon;
}

@immutable
class ListQuery {
  const ListQuery({
    this.search = '',
    this.type,
    this.status,
    this.sort = SortOption.recent,
    this.grid = false,
  });

  final String search;
  final EntryType? type;
  final EntryStatus? status; // library tab only
  final SortOption sort;
  final bool grid;

  bool get isFiltered => search.trim().isNotEmpty || type != null || status != null;

  /// Drag-to-reorder only makes sense on the full, unfiltered custom order.
  bool get canReorder => sort == SortOption.custom && !isFiltered && !grid;

  ListQuery copyWith({
    String? search,
    Nullable<EntryType>? type,
    Nullable<EntryStatus>? status,
    SortOption? sort,
    bool? grid,
  }) =>
      ListQuery(
        search: search ?? this.search,
        type: type != null ? type.value : this.type,
        status: status != null ? status.value : this.status,
        sort: sort ?? this.sort,
        grid: grid ?? this.grid,
      );
}

final listQueryProvider =
    StateProvider.family<ListQuery, ListTab>((ref, tab) => const ListQuery());

/// Entries for a tab, after search / filters / sort.
final visibleEntriesProvider =
    Provider.family<List<Entry>, ListTab>((ref, tab) {
  final all = ref.watch(entriesProvider).value ?? const <Entry>[];
  final q = ref.watch(listQueryProvider(tab));
  final needle = q.search.trim().toLowerCase();

  final list = all.where((e) {
    if (tab == ListTab.toRead) {
      if (e.status != EntryStatus.toRead) return false;
    } else {
      if (e.status == EntryStatus.toRead) return false;
      if (q.status != null && e.status != q.status) return false;
    }
    if (q.type != null && e.type != q.type) return false;
    if (needle.isEmpty) return true;
    return e.title.toLowerCase().contains(needle) ||
        (e.author?.toLowerCase().contains(needle) ?? false);
  }).toList();

  switch (q.sort) {
    case SortOption.recent:
      list.sort((a, b) => b.activityAt.compareTo(a.activityAt));
    case SortOption.added:
      list.sort((a, b) => (b.createdAt ?? DateTime(0))
          .compareTo(a.createdAt ?? DateTime(0)));
    case SortOption.title:
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    case SortOption.progress:
      list.sort((a, b) => b.chapter.compareTo(a.chapter));
    case SortOption.custom:
      list.sort((a, b) => a.position.compareTo(b.position));
  }
  return list;
});

/// Count of library titles per status (for the filter chips).
final statusCountsProvider = Provider<Map<EntryStatus, int>>((ref) {
  final all = ref.watch(entriesProvider).value ?? const <Entry>[];
  final counts = {for (final s in EntryStatus.values) s: 0};
  for (final e in all) {
    counts[e.status] = counts[e.status]! + 1;
  }
  return counts;
});

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

final chaptersPerDayProvider =
    FutureProvider<List<({DateTime day, int chapters})>>((ref) async {
  final repo = ref.watch(repositoryProvider);
  if (repo == null) return const [];
  return repo.chaptersPerDay(days: 14);
});

final completionsPerMonthProvider =
    FutureProvider<List<({DateTime month, int count})>>((ref) async {
  final repo = ref.watch(repositoryProvider);
  if (repo == null) return const [];
  return repo.completionsPerMonth(months: 6);
});

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

@immutable
class Profile {
  const Profile({this.username, this.listVisible = true});
  final String? username;
  final bool listVisible;
}

final profileProvider = FutureProvider<Profile>((ref) async {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return const Profile();
  final row = await ref
      .watch(supabaseProvider)
      .from('profiles')
      .select('username, list_visible')
      .eq('id', uid)
      .maybeSingle();
  if (row == null) return const Profile();
  return Profile(
    username: row['username'] as String?,
    listVisible: (row['list_visible'] as bool?) ?? true,
  );
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Turns exceptions into a sentence fit for a snackbar.
String friendlyError(Object e) {
  if (e is AuthException) return e.message;
  if (e is PostgrestException) return e.message;
  if (e is DataException) return e.message;
  if (e is AniListException) return e.message;
  if (e is MangaDexException) return e.message;
  final s = e.toString();
  if (s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Failed host lookup') ||
      s.contains('TimeoutException')) {
    return "You're offline. Your changes are saved on this phone and will sync when you're back online.";
  }
  return s.replaceFirst('Exception: ', '');
}
