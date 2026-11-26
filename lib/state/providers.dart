import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/entry.dart';
import '../services/anilist.dart';
import '../services/background.dart';
import '../services/extension_covers.dart';
import '../services/local_store.dart';
import '../services/mangadex.dart';
import '../services/sources/reader_source.dart';
import '../services/update_checker.dart';
import '../utils/import_merge.dart';
import 'inbox.dart';

// ---------------------------------------------------------------------------
// Core services
// ---------------------------------------------------------------------------

/// Loaded once in main() so settings are known before the first frame.
final sharedPrefsProvider = Provider<SharedPreferences>(
    (ref) => throw UnimplementedError('Override in main()'));

final aniListProvider = Provider<AniListService>((ref) => AniListService());

final mangaDexProvider = Provider<MangaDexService>((ref) => MangaDexService());

/// True while a new-chapter check is running in the app.
final updateCheckingProvider = StateProvider<bool>((ref) => false);

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

/// False after an online job (new chapters, covers, chapter lists) found no
/// connection. Everything in the library keeps working; it's only shown so
/// people know why new chapters / covers aren't updating.
final onlineProvider = StateProvider<bool>((ref) => true);

/// Progress of the background "find missing covers" job, or null when idle.
final coverFillProvider =
    StateProvider<({int done, int total})?>((ref) => null);

/// The list, saved on the phone only (see [LocalStore]). Every change is
/// saved straight away and works with no connection. Online extras — new
/// chapter checks and missing covers — run when the app opens, when it
/// comes back to the foreground, and on pull-to-refresh, and quietly wait
/// for the next try when offline.
class EntriesNotifier extends AsyncNotifier<List<Entry>> {
  List<Entry> get _current => state.value ?? const [];

  AppLifecycleListener? _lifecycle;

  @override
  Future<List<Entry>> build() async {
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    ref.onDispose(() => _lifecycle?.dispose());

    // Fold in what the background job found while the app was closed.
    // (Patches hold absolute values, so applying one twice is harmless.)
    final saved = LocalStore.applyPatches(await LocalStore.readEntries(),
        await LocalStore.takeBackgroundPatches());
    unawaited(LocalStore.writeEntries(saved));
    // After the list is on screen: covers and the new-chapter check.
    unawaited(Future<void>.delayed(Duration.zero, refresh));
    return saved;
  }

  // ---- local state ----

  void _set(List<Entry> list) {
    state = AsyncData(list);
    unawaited(LocalStore.writeEntries(list));
  }

  void _setOnline(bool v) {
    if (ref.read(onlineProvider) != v) {
      ref.read(onlineProvider.notifier).state = v;
    }
  }

  /// Applies a column patch (e.g. from the update check) to one title.
  /// New-chapter info only: reading progress is stripped, so new chapters
  /// coming out move `latest_chapter` and never `chapter`.
  Future<void> _patch(String id, Map<String, dynamic> patch) async {
    patch = LocalStore.withoutProgress(patch);
    if (patch.isEmpty) return;
    _set([
      for (final e in _current)
        e.id == id ? LocalStore.applyPatch(e, patch) : e,
    ]);
  }

  static bool isConnectionProblem(Object e) {
    final s = e.toString();
    return e is UpdateOffline ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup') ||
        s.contains('TimeoutException') ||
        s.contains('HandshakeException');
  }

  /// Picks up the background job's findings, then looks up covers for any
  /// titles that don't have one yet and checks for new chapters. Both run
  /// in the background after the list is shown; [manual] (pull-to-refresh)
  /// checks chapters now instead of every 5 hours.
  Future<void> refresh({bool manual = false}) async {
    if (!state.hasValue) return;
    final patches = await LocalStore.takeBackgroundPatches();
    if (patches.isNotEmpty) _set(LocalStore.applyPatches(_current, patches));
    if (!ref.read(onlineProvider)) await _probe();
    unawaited(fillMissingCovers());
    if (manual) {
      await checkUpdates(force: true);
    } else {
      unawaited(checkUpdates());
    }
  }

  /// After being offline: a tiny request to see if the connection is back
  /// (clears the "You're offline" banner even when nothing else is due).
  Future<void> _probe() async {
    try {
      final res = await http
          .get(Uri.https('api.mangadex.org', '/ping'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode < 500) _setOnline(true);
    } catch (_) {}
  }

  // ---- new chapters ----

  bool _checking = false;

  /// Checks titles you're reading for new chapters — at most every 5 hours
  /// unless [force] is set. The background job does the same while the app
  /// is closed; whichever runs first resets the 5-hour clock.
  Future<void> checkUpdates({bool force = false}) async {
    if (_checking) return;
    final checker = UpdateChecker(source: ref.read(mangaDexProvider));
    if (!force && !await checker.isDue()) return;
    _checking = true;
    ref.read(updateCheckingProvider.notifier).state = true;
    try {
      // Progress shows as a quiet notification, not a banner in the list.
      final updates = await checker.run(
        _current,
        _patch,
        onProgress: (done, total) => Notifications.showProgress(
            Notifications.chaptersProgressId, 'Checking for new chapters',
            done: done, total: total),
      );
      _setOnline(true);
      await Notifications.showUpdates(updates);
      if (updates.isNotEmpty) await ref.read(inboxProvider.notifier).reload();
    } catch (e) {
      // Offline — the next check will try again.
      if (isConnectionProblem(e)) _setOnline(false);
    } finally {
      _checking = false;
      ref.read(updateCheckingProvider.notifier).state = false;
      await Notifications.endProgress(Notifications.chaptersProgressId);
    }
  }

  /// Links [e] to a series picked by hand. Uses its cover (the accurate one
  /// from the source) unless [keepCover] is set, and reads its newest chapter.
  Future<void> linkSource(Entry e, SourceManga m, {bool keepCover = false}) async {
    int? latest;
    try {
      latest = await ref.read(mangaDexProvider).latestChapter(m.id);
    } catch (_) {}
    final now = DateTime.now();
    await save(
      e,
      e.copyWith(
        sourceId: Nullable(m.sourceId),
        latestChapter: Nullable(latest),
        latestCheckedAt: Nullable(now),
        coverUrl: (!keepCover && m.coverUrl != null) ? Nullable(m.coverUrl) : null,
      ),
      {
        'source_id': m.sourceId,
        'latest_chapter': latest,
        'latest_checked_at': now.toUtc().toIso8601String(),
        if (!keepCover && m.coverUrl != null) 'cover_url': m.coverUrl,
      },
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

  /// The reading source's chapter list just loaded: if it has more chapters
  /// than we knew about, show them as new (no notification).
  Future<void> noteLatestFromReader(String entryId, int latest) async {
    final e = _current.where((x) => x.id == entryId).firstOrNull;
    if (e == null || (e.latestChapter ?? -1) >= latest) return;
    await _patch(e.id, {
      'latest_chapter': latest,
      'latest_checked_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ---- changes ----

  int _topPosition() {
    final list = _current;
    if (list.isEmpty) return 0;
    return list.map((e) => e.position).reduce((a, b) => a < b ? a : b) - 1;
  }

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

  /// Applies [optimistic] and saves it. [patch] lists the columns that
  /// changed (used for the Stats logs and to stamp "last read").
  Future<void> save(Entry before, Entry optimistic,
      Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    var after = optimistic;
    if (patch.containsKey('chapter')) {
      after = after.copyWith(lastReadAt: DateTime.now());
    }
    _set([
      for (final e in _current) e.id == before.id ? after : e,
    ]);
    if (before.status != EntryStatus.finished &&
        after.status == EntryStatus.finished) {
      unawaited(HapticFeedback.mediumImpact());
    }
    await LocalStore.recordActivity(before, after, patch);
  }

  Future<void> bumpChapter(Entry e, int by) async {
    final raw = e.chapter + by;
    await setChapter(e, raw < 0 ? 0 : raw, haptic: true);
  }

  /// Sets the chapter you're on. Reading anything of a To Read title moves
  /// it into the library automatically.
  Future<void> setChapter(Entry e, int next, {bool haptic = false}) async {
    if (next == e.chapter) return;
    if (haptic) unawaited(HapticFeedback.selectionClick());
    final patch = <String, dynamic>{'chapter': next};
    var optimistic = e.copyWith(chapter: next, lastReadAt: DateTime.now());
    if (next > e.chapter && e.status == EntryStatus.toRead) {
      patch['status'] = EntryStatus.reading.label;
      optimistic = optimistic.copyWith(status: EntryStatus.reading);
    }
    await save(e, optimistic, patch);
  }

  /// Called by the reader: you finished chapter [number] of [entryId].
  /// Only ever moves progress forward.
  Future<void> markReadUpTo(String entryId, int number) async {
    final e = _current.where((x) => x.id == entryId).firstOrNull;
    if (e == null || number <= e.chapter) return;
    await setChapter(e, number);
  }

  /// Just stamps "last read" (opening the reader counts as activity).
  void touch(String entryId) {
    _set([
      for (final e in _current)
        e.id == entryId ? e.copyWith(lastReadAt: DateTime.now()) : e,
    ]);
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
    return e;
  }

  /// Puts a deleted entry back exactly as it was (same id, so its reading
  /// source, progress and downloads still match).
  Future<void> restore(Entry e) async {
    if (_current.any((x) => x.id == e.id)) return;
    final list = [..._current, e]
      ..sort((a, b) => a.position.compareTo(b.position));
    _set(list);
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

    var changed = false;
    final next = <Entry>[];
    for (var i = 0; i < ordered.length; i++) {
      final e = ordered[i];
      if (e.position != i) changed = true;
      next.add(e.position == i ? e : e.copyWith(position: i));
    }
    if (!changed) return;
    unawaited(HapticFeedback.selectionClick());
    _set(next);
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

    final updates = <String, Entry>{};
    for (final u in plan.toUpdate) {
      final e = u.existing;
      final p = u.incoming;
      final reread = p.reread > e.reread ? p.reread : e.reread;
      updates[e.id] = e.copyWith(
        chapter: p.chapter,
        status: p.status,
        reread: reread,
        lastReadAt: now,
      );
    }

    final list = [
      ...added,
      for (final e in _current) updates[e.id] ?? e,
    ]..sort((a, b) => a.position.compareTo(b.position));
    // No Stats logs here: catching up an old list shouldn't show up as
    // hundreds of chapters "read today".
    _set(list);
    unawaited(fillMissingCovers());
    return (added: added.length, updated: updates.length);
  }

  bool _filling = false;
  bool _fillAgain = false;

  /// Titles already looked up this session that AniList had no cover for,
  /// so every refresh doesn't search for them again.
  final Set<String> _noCoverFound = {};

  /// Signature of the extension sites the last cover search used.
  String? _extSignature;

  /// Looks up covers (plus author / chapter count if missing) on AniList,
  /// then MangaDex, then the sites of installed extensions, for titles that
  /// don't have a cover yet. Runs one title at a time in the background,
  /// saves each as it's found, and stops quietly when offline. Progress
  /// shows as a quiet notification. Comics only go to the extensions
  /// (AniList barely has any).
  Future<void> fillMissingCovers() async {
    if (_filling) {
      _fillAgain = true;
      return;
    }
    _filling = true;
    final ExtensionCoverFinder ext;
    try {
      ext = await ExtensionCoverFinder.load();
    } catch (_) {
      _filling = false;
      return;
    }
    if (_extSignature != ext.signature) {
      // Extensions changed: titles not found before may be found now.
      _extSignature = ext.signature;
      _noCoverFound.clear();
    }
    bool needsCover(Entry e) =>
        (e.coverUrl == null || e.coverUrl!.trim().isEmpty) &&
        (e.type != EntryType.comic || ext.isNotEmpty) &&
        !_noCoverFound.contains(titleKey(e.title));

    final todo = _current.where(needsCover).map((e) => e.id).toList();
    if (todo.isEmpty) {
      _filling = false;
      if (_fillAgain) {
        _fillAgain = false;
        unawaited(fillMissingCovers());
      }
      return;
    }
    final progress = ref.read(coverFillProvider.notifier);
    progress.state = (done: 0, total: todo.length);
    unawaited(Notifications.showProgress(
        Notifications.coversProgressId, 'Finding covers',
        done: 0, total: todo.length));
    final anilist = ref.read(aniListProvider);
    try {
      var busyRetries = 0;
      for (var i = 0; i < todo.length; i++) {
        // Re-read: the title may have been edited or deleted meanwhile.
        final e = _current.where((x) => x.id == todo[i]).firstOrNull;
        if (e != null && needsCover(e)) {
          SearchResult? match;
          String? cover;
          if (e.type != EntryType.comic) {
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
            } catch (err) {
              if (isConnectionProblem(err)) _setOnline(false);
              return; // offline — try again next refresh
            }
            _setOnline(true);
            cover = match?.coverUrl;
            if (cover == null || cover.isEmpty) {
              // Not on AniList (or no cover there): try MangaDex.
              try {
                cover = (await ref.read(mangaDexProvider).findExact(e.title))
                    ?.coverUrl;
              } catch (_) {}
            }
          }
          if ((cover == null || cover.isEmpty) && ext.isNotEmpty) {
            // Last try: the sites of the extensions you installed.
            cover = await ext.find(e.title);
          }
          // Look it up again in case it changed during the request.
          final now = _current.where((x) => x.id == e.id).firstOrNull;
          if (cover == null || cover.isEmpty) {
            _noCoverFound.add(titleKey(e.title));
          } else if (now != null && needsCover(now)) {
            var after = now.copyWith(coverUrl: Nullable(cover));
            if (now.author == null && match?.author != null) {
              after = after.copyWith(author: Nullable(match!.author));
            }
            if (now.totalChapters == null && match?.totalChapters != null) {
              after =
                  after.copyWith(totalChapters: Nullable(match!.totalChapters));
            }
            _set([for (final x in _current) x.id == now.id ? after : x]);
          }
          // Stay well under AniList's rate limit.
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
        progress.state = (done: i + 1, total: todo.length);
        unawaited(Notifications.showProgress(
            Notifications.coversProgressId, 'Finding covers',
            done: i + 1, total: todo.length));
      }
    } finally {
      _filling = false;
      progress.state = null;
      unawaited(Notifications.endProgress(Notifications.coversProgressId));
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
    FutureProvider<List<({DateTime day, int chapters})>>(
        (ref) => LocalStore.chaptersPerDay(days: 14));

final completionsPerMonthProvider =
    FutureProvider<List<({DateTime month, int count})>>(
        (ref) => LocalStore.completionsPerMonth(months: 6));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Turns exceptions into a sentence fit for a snackbar.
String friendlyError(Object e) {
  if (e is AniListException) return e.message;
  if (e is MangaDexException) return e.message;
  if (e is SourceException) return e.message;
  if (EntriesNotifier.isConnectionProblem(e)) {
    return "You're offline. Your library still works; this needs a connection.";
  }
  return e.toString().replaceFirst('Exception: ', '');
}
