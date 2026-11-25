import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entry.dart';
import '../services/anilist.dart';
import '../services/entries_repository.dart';

// ---------------------------------------------------------------------------
// Core services
// ---------------------------------------------------------------------------

final supabaseProvider =
    Provider<SupabaseClient>((ref) => Supabase.instance.client);

final aniListProvider = Provider<AniListService>((ref) => AniListService());

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

/// Non-null while the last sync with Supabase failed (shown as a banner).
final syncErrorProvider = StateProvider<String?>((ref) => null);

class EntriesNotifier extends AsyncNotifier<List<Entry>> {
  EntriesRepository get _repo => ref.read(repositoryProvider)!;

  List<Entry> get _current => state.value ?? const [];

  @override
  Future<List<Entry>> build() async {
    final repo = ref.watch(repositoryProvider);
    if (repo == null) return const [];

    final cached = await repo.readCache();
    if (cached != null) {
      // Show the cached list instantly, then refresh from the server.
      Future.microtask(refresh);
      return cached;
    }
    final fresh = await repo.fetchAll();
    unawaited(repo.writeCache(fresh));
    return fresh;
  }

  void _set(List<Entry> list) {
    state = AsyncData(list);
    final repo = ref.read(repositoryProvider);
    if (repo != null) unawaited(repo.writeCache(list));
  }

  void _syncOk() => ref.read(syncErrorProvider.notifier).state = null;
  void _syncFailed(Object e) =>
      ref.read(syncErrorProvider.notifier).state = friendlyError(e);

  Future<void> refresh() async {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    try {
      final fresh = await repo.fetchAll();
      _set(fresh);
      _syncOk();
    } catch (e) {
      _syncFailed(e);
      if (!state.hasValue) state = AsyncError(e, StackTrace.current);
    }
  }

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
    final entry = await _repo.insert(
      title: title,
      type: type,
      status: status,
      chapter: chapter,
      position: _topPosition(),
      coverUrl: coverUrl,
      author: author,
      totalChapters: totalChapters,
      readOnUrl: readOnUrl,
    );
    _set([entry, ..._current]);
    _syncOk();
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

  /// Optimistically applies [optimistic] locally, then saves [patch].
  /// Rolls back and rethrows if the save fails.
  Future<void> save(Entry before, Entry optimistic,
      Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    final previous = _current;
    state = AsyncData([
      for (final e in previous) e.id == before.id ? optimistic : e,
    ]);
    try {
      final saved = await _repo.update(before, patch);
      _set([
        for (final e in _current) e.id == before.id ? saved : e,
      ]);
      _syncOk();
      if (before.status != EntryStatus.finished &&
          saved.status == EntryStatus.finished) {
        unawaited(HapticFeedback.mediumImpact());
      }
    } catch (e) {
      state = AsyncData(previous);
      _syncFailed(e);
      rethrow;
    }
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
    final previous = _current;
    state = AsyncData(previous.where((x) => x.id != e.id).toList());
    try {
      await _repo.delete(e.id);
      _set(_current);
      _syncOk();
      unawaited(HapticFeedback.lightImpact());
      return e;
    } catch (err) {
      state = AsyncData(previous);
      _syncFailed(err);
      rethrow;
    }
  }

  /// Puts a deleted entry back (gets a new id; keeps everything else).
  Future<void> restore(Entry e) async {
    final restored = await _repo.insert(
      title: e.title,
      type: e.type,
      status: e.status,
      chapter: e.chapter,
      reread: e.reread,
      position: e.position,
      coverUrl: e.coverUrl,
      author: e.author,
      totalChapters: e.totalChapters,
      readOnUrl: e.readOnUrl,
    );
    final list = [..._current, restored]
      ..sort((a, b) => a.position.compareTo(b.position));
    _set(list);
    _syncOk();
  }

  /// Moves [moved] to sit where [target] is, in the custom ("My order") sort.
  Future<void> reorder(String movedId, String targetId) async {
    if (movedId == targetId) return;
    final previous = _current;
    final ordered = [...previous]
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
    state = AsyncData(next);
    try {
      await _repo.setPositions(changed);
      _set(next);
      _syncOk();
    } catch (e) {
      state = AsyncData(previous);
      _syncFailed(e);
      rethrow;
    }
  }

  /// Bulk import. Optionally looks each title up on AniList for its cover,
  /// author and chapter count. Returns how many were added.
  Future<int> importAll(
    List<({String title, EntryType type, EntryStatus status, int chapter, int reread})>
        items, {
    bool enrich = true,
    void Function(int done, int total)? onProgress,
  }) async {
    if (items.isEmpty) return 0;
    final anilist = ref.read(aniListProvider);
    var top = _topPosition();
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      SearchResult? match;
      if (enrich && it.type != EntryType.comic) {
        match = await anilist.findMatch(it.title);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      rows.add({
        'title': it.title,
        'type': it.type.label,
        'status': it.status.label,
        'chapter': it.chapter,
        'reread': it.reread,
        'position': top--,
        'cover_url': match?.coverUrl,
        'author': match?.author,
        'total_chapters': match?.totalChapters,
      });
      onProgress?.call(i + 1, items.length);
    }
    final added = await _repo.insertMany(rows);
    final list = [...added, ..._current]
      ..sort((a, b) => a.position.compareTo(b.position));
    _set(list);
    _syncOk();
    return added.length;
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
  final s = e.toString();
  if (s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Failed host lookup') ||
      s.contains('TimeoutException')) {
    return "You're offline — changes will need a connection to save.";
  }
  return s.replaceFirst('Exception: ', '');
}
