  import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/chapter_cache.dart';
import '../services/extension_repo.dart' show Extension;
import '../services/sources/apk_source.dart';
import '../services/sources/mangadex_source.dart';
import '../services/sources/reader_source.dart';
import '../services/sources/site_source.dart';
import 'downloads.dart';
import 'extensions.dart';
import 'providers.dart';

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

/// Every source Panel can read from right now.
class ReaderSourceRegistry {
  ReaderSourceRegistry({
    required this.mangadex,
    required this.installed,
    required this.available,
  })  : _byId = {
          for (final s in [...installed, ...available]) s.id: s,
        },
        _nativeByOrigin = {
          for (final s in installed)
            if (s is ApkSource && (s.baseUrl ?? '').isNotEmpty)
              SiteSource.origin(s.baseUrl!): s,
        };

  final MangaDexSource mangadex;

  /// Sources of the extensions installed on the phone: on Android, trusted
  /// extensions run natively ([ApkSource]); the rest are read as websites
  /// ([SiteSource]).
  final List<ReaderSource> installed;

  /// Other (non-18+) sites listed by your repos, not installed.
  final List<SiteSource> available;

  final Map<String, ReaderSource> _byId;

  /// Natively loaded extension sources by site origin, to spot old website
  /// links for a site whose extension now runs natively.
  final Map<String, ApkSource> _nativeByOrigin;

  /// Searched together when picking a source for a title.
  List<ReaderSource> get primary => [mangadex, ...installed];

  /// The source a title is linked to. Works even if the extension was
  /// uninstalled or the repos can't be reached: the link remembers the site.
  ReaderSource forLink(ReadingLink l) {
    if (l.sourceId == MangaDexSource.sourceId) return mangadex;
    final known = _byId[l.sourceId];
    if (known != null) return known;
    if (l.sourceId.startsWith(ApkSource.prefix)) {
      // Extension uninstalled or untrusted (or not on Android): explains itself.
      return ApkSource.missing(
          id: l.sourceId,
          name: l.sourceName,
          lang: l.sourceLang,
          baseUrl: l.sourceBaseUrl);
    }
    final base = l.sourceBaseUrl ?? l.sourceId.replaceFirst('site:', '');
    // Linked back when this extension was read as a website. Its series keys
    // are full web urls, which the native extension can't use, so the link
    // can't be moved silently — but the error should say how to fix it.
    final native = _nativeByOrigin[SiteSource.origin(base)];
    return SiteSource(
      name: l.sourceName,
      lang: l.sourceLang,
      baseUrl: base,
      unsupportedReason: native == null
          ? null
          : 'This title was linked to ${l.sourceName} as a website. Panel now '
              'runs the ${native.name} extension itself: tap "Change source" '
              'and pick ${native.name} again.',
    );
  }
}

/// Why an installed extension is being read as a plain website instead of
/// running natively, worded for the user. Null off Android (website reading
/// is the only option there, so the usual message fits).
String? _notNativeReason(ApkExtensions apk, Extension e) {
  if (!ApkBridge.supported) return null;
  final err = apk.errorFor(e.pkg);
  if (err != null && err.untrusted) {
    return "${e.name}'s extension is installed but not trusted yet. Trust it "
        'in Settings → Extension store to read it here.';
  }
  if (err != null) {
    final why = err.reason.trim();
    return "${e.name}'s extension couldn't be loaded"
        '${why.isEmpty ? '' : ' ($why)'}. Update or reinstall it, '
        'or pick another source.';
  }
  if (!apk.loaded) {
    return "${e.name}'s extension is still loading. Try again in a moment.";
  }
  return "${e.name}'s extension isn't running yet. Reload extensions in the "
      'Extension store, or pick another source.';
}

final readerSourcesProvider = Provider<ReaderSourceRegistry>((ref) {
  // Only rebuild when repos or installed apps change (not on APK progress).
  ref.watch(extensionStoreProvider
      .select((s) => (s.repoUrls, s.repos, s.installed)));
  final store = ref.read(extensionStoreProvider);
  // Installed extensions Panel runs natively (Android, trusted).
  final apk = ref.watch(apkExtensionsProvider);
  final native = {for (final s in apk.sources) s.pkg};
  final seen = <String>{};
  final installed = <ReaderSource>[
    for (final s in apk.sources)
      // MangaDex is built in (through its API).
      if (!(s.baseUrl ?? '').contains('mangadex.org') && seen.add(s.id)) s,
  ];
  final available = <SiteSource>[];
  for (final e in store.extensions) {
    final isInstalled = store.isInstalled(e);
    if (!isInstalled && e.isNsfw) continue;
    // Runs natively: its own code replaces Panel's website reader.
    if (isInstalled && native.contains(e.pkg)) continue;
    // Installed but not running natively (untrusted, failed, or still
    // loading): still try the site as a website (common themes work), but
    // when that fails say why, not "uses its own site layout".
    final reason = isInstalled ? _notNativeReason(apk, e) : null;
    for (final s in e.sources) {
      // MangaDex is built in (through its API).
      if (s.baseUrl.contains('mangadex.org')) continue;
      final src = SiteSource.fromExt(s, unsupportedReason: reason);
      if (!seen.add(src.id)) continue;
      if (isInstalled) {
        installed.add(src);
      } else {
        available.add(src);
      }
    }
  }
  int rank(ReaderSource s) => switch (s.lang) { 'en' => 0, 'all' => 1, _ => 2 };
  int order(ReaderSource a, ReaderSource b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  installed.sort(order);
  available.sort(order);
  return ReaderSourceRegistry(
    mangadex: MangaDexSource(ref.read(mangaDexProvider)),
    installed: installed,
    available: available,
  );
});

// ---------------------------------------------------------------------------
// Per-title reading links (source, scanlators, where you stopped)
// ---------------------------------------------------------------------------

class ReadingLinksNotifier extends Notifier<Map<String, ReadingLink>> {
  static const _key = 'reading_links_v1';

  @override
  Map<String, ReadingLink> build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const {};
      return {
        for (final e in j.entries)
          if (ReadingLink.fromJson(e.value) case final l?) '${e.key}': l,
      };
    } catch (_) {
      return const {};
    }
  }

  void _put(String entryId, ReadingLink? link) {
    final next = {...state};
    if (link == null) {
      next.remove(entryId);
    } else {
      next[entryId] = link;
    }
    state = next;
    unawaited(ref.read(sharedPrefsProvider).setString(_key,
        jsonEncode({for (final e in next.entries) e.key: e.value.toJson()})));
  }

  /// Reads [entryId] from [series] on [source] from now on. Keeps the chapter
  /// number you were on so Resume still lands in the right place.
  void choose(String entryId, ReaderSource source, SourceSeries series) {
    final old = state[entryId];
    final base = switch (source) {
      SiteSource s => s.base,
      ApkSource s => s.baseUrl,
      _ => null,
    };
    final link = old != null
        ? old.movedTo(
            sourceId: source.id,
            sourceName: source.name,
            sourceLang: source.lang,
            sourceBaseUrl: base,
            series: series)
        : ReadingLink(
            sourceId: source.id,
            sourceName: source.name,
            sourceLang: source.lang,
            sourceBaseUrl: base,
            seriesKey: series.key,
            seriesTitle: series.title,
            seriesUrl: series.url,
          );
    _put(entryId, link);
  }

  void setScanlators(String entryId, Set<String> scanlators) {
    final l = state[entryId];
    if (l != null) _put(entryId, l.copyWith(scanlators: scanlators));
  }

  /// Where you are in the reader: chapter, page and how far down that page
  /// ([offset], 0..1). Saved on the phone per title, so it survives closing
  /// the app. [finished] = you reached the last page.
  ///
  /// Only the reader's bookmark changes here. The library's chapter count
  /// (chapters read) moves separately, when you actually finish a chapter.
  void saveProgress(String entryId, ChapterInfo chapter,
      {required int page,
      double offset = 0,
      int? pageCount,
      bool finished = false}) {
    final l = state[entryId];
    if (l == null) return;
    final sameChapter = l.lastChapterKey == chapter.key;
    final o = offset.isFinite ? offset.clamp(0.0, 1.0).toDouble() : 0.0;
    // Nothing moved: skip the write (the reader saves often).
    if (sameChapter &&
        l.lastPage == page &&
        (l.lastPageOffset - o).abs() < 0.01 &&
        l.lastPageCount == pageCount &&
        l.lastFinished == (finished || l.lastFinished)) {
      return;
    }
    _put(
      entryId,
      l.copyWith(
        lastChapterKey: chapter.key,
        lastChapterNumber: chapter.number,
        lastScanlator: chapter.scanlatorLabel,
        lastPage: page,
        lastPageOffset: o,
        lastPageCount: pageCount,
        // Once finished, scrolling back up doesn't un-finish a chapter.
        lastFinished: finished || (sameChapter && l.lastFinished),
        lastReadAt: DateTime.now(),
      ),
    );
  }

  void unlink(String entryId) => _put(entryId, null);
}

final readingLinksProvider =
    NotifierProvider<ReadingLinksNotifier, Map<String, ReadingLink>>(
        ReadingLinksNotifier.new);

// ---------------------------------------------------------------------------
// Chapters you finished in the reader
// ---------------------------------------------------------------------------

/// The chapters you read to the end in the reader, per title (by the
/// source's chapter key). Saved on the phone. This is what makes finishing
/// a chapter count exactly once: reaching the last page, scrolling past the
/// end and tapping "Next" all call [finish], and only the first call for a
/// chapter records anything.
class ReadChaptersNotifier extends Notifier<Map<String, Set<String>>> {
  static const _key = 'read_chapters_v1';

  /// Most recent keys kept per title; plenty for any series, and keeps the
  /// saved data small.
  static const maxPerTitle = 2000;

  @override
  Map<String, Set<String>> build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const {};
      return {
        for (final e in j.entries)
          if (e.value is List)
            '${e.key}': {
              for (final k in e.value as List)
                if (k is String) k,
            },
      };
    } catch (_) {
      return const {};
    }
  }

  bool isRead(String entryId, String chapterKey) =>
      state[entryId]?.contains(chapterKey) ?? false;

  /// You finished [chapter] of [entryId]: remember it and move the
  /// library's chapter count forward (never back). Returns false, and does
  /// nothing, when this chapter was already recorded.
  bool finish(String entryId, ChapterInfo chapter) {
    final had = state[entryId] ?? const <String>{};
    if (had.contains(chapter.key)) return false;
    // Insertion order = oldest first, so trimming drops the oldest.
    var keys = <String>{...had, chapter.key};
    if (keys.length > maxPerTitle) {
      keys = keys.skip(keys.length - maxPerTitle).toSet();
    }
    state = {...state, entryId: keys};
    unawaited(ref.read(sharedPrefsProvider).setString(_key,
        jsonEncode({for (final e in state.entries) e.key: e.value.toList()})));
    final n = chapter.number;
    if (n != null) {
      unawaited(
          ref.read(entriesProvider.notifier).markReadUpTo(entryId, n.floor()));
    }
    return true;
  }

  /// Forgets a title's finished chapters (e.g. it was removed).
  void clear(String entryId) {
    if (!state.containsKey(entryId)) return;
    state = {...state}..remove(entryId);
    unawaited(ref.read(sharedPrefsProvider).setString(_key,
        jsonEncode({for (final e in state.entries) e.key: e.value.toList()})));
  }
}

final readChaptersProvider =
    NotifierProvider<ReadChaptersNotifier, Map<String, Set<String>>>(
        ReadChaptersNotifier.new);

// ---------------------------------------------------------------------------
// Reading mode (paged right-to-left / left-to-right, long strip)
// ---------------------------------------------------------------------------

/// Reading modes you picked by hand, per title. Kept apart from the reading
/// link so the choice survives switching or unlinking the source.
class ReadingModesNotifier extends Notifier<Map<String, ReadingMode>> {
  static const _key = 'reading_modes_v1';

  @override
  Map<String, ReadingMode> build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const {};
      return {
        for (final e in j.entries)
          if (ReadingMode.fromKey(e.value) case final m?) '${e.key}': m,
      };
    } catch (_) {
      return const {};
    }
  }

  /// [mode] = null goes back to the default for the title's type.
  void set(String entryId, ReadingMode? mode) {
    if (state[entryId] == mode) return;
    final next = {...state};
    if (mode == null) {
      next.remove(entryId);
    } else {
      next[entryId] = mode;
    }
    state = next;
    unawaited(ref.read(sharedPrefsProvider).setString(_key,
        jsonEncode({for (final e in next.entries) e.key: e.value.key})));
  }
}

final readingModesProvider =
    NotifierProvider<ReadingModesNotifier, Map<String, ReadingMode>>(
        ReadingModesNotifier.new);

/// The mode a title reads in: the one you picked for it, otherwise the
/// default for its type ([defaultReadingMode]).
final readingModeProvider =
    Provider.family<ReadingMode, String>((ref, entryId) {
  final picked = ref.watch(readingModesProvider.select((m) => m[entryId]));
  if (picked != null) return picked;
  final type = ref.watch(entriesProvider.select((s) => (s.value ?? const [])
      .where((e) => e.id == entryId)
      .firstOrNull
      ?.type
      .label));
  return defaultReadingMode(type);
});

// ---------------------------------------------------------------------------
// Chapter lists (offline first)
// ---------------------------------------------------------------------------

class ChapterList {
  const ChapterList({
    this.chapters = const [],
    this.fetchedAt,
    this.loading = false,
    this.error,
    this.downloadedOnly = false,
  });

  /// Newest first, as the source lists them.
  final List<ChapterInfo> chapters;
  final DateTime? fetchedAt;

  /// Asking the source right now.
  final bool loading;

  /// The last try failed (the saved list, if any, is still shown).
  final SourceException? error;

  /// Offline with no saved list: only downloaded chapters are known.
  final bool downloadedOnly;

  ChapterList copyWith({bool? loading, SourceException? error, bool clearError = false}) =>
      ChapterList(
        chapters: chapters,
        fetchedAt: fetchedAt,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        downloadedOnly: downloadedOnly,
      );
}

/// The chapter list of one title on its chosen source. Shows the copy saved
/// on the phone straight away, then asks the source for a fresh one when
/// there's a connection. Never throws: errors are kept in [ChapterList.error].
class ChaptersNotifier extends Notifier<ChapterList> {
  ChaptersNotifier(this.entryId);
  final String entryId;

  int _gen = 0;

  @override
  ChapterList build() {
    final key = ref.watch(readingLinksProvider.select((m) {
      final l = m[entryId];
      return l == null ? null : '${l.sourceId}\n${l.seriesKey}';
    }));
    final gen = ++_gen;
    if (key == null) return const ChapterList();
    unawaited(Future<void>.delayed(Duration.zero, () => _load(gen)));
    return const ChapterList(loading: true);
  }

  bool _live(int gen) => ref.mounted && gen == _gen;

  Future<void> _load(int gen) async {
    final link = ref.read(readingLinksProvider)[entryId];
    if (link == null || !_live(gen)) return;
    final cached = await ChapterCache.read(link.sourceId, link.seriesKey);
    if (!_live(gen)) return;
    if (cached != null && cached.chapters.isNotEmpty) {
      state = ChapterList(
          chapters: cached.chapters, fetchedAt: cached.fetchedAt, loading: true);
    }
    await _fetch(gen);
  }

  /// Asks the source again (pull to refresh).
  Future<void> refresh() => _fetch(_gen);

  Future<void> _fetch(int gen) async {
    final link = ref.read(readingLinksProvider)[entryId];
    if (link == null || !_live(gen)) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final source = ref.read(readerSourcesProvider).forLink(link);
      final list = await source.chapters(link.seriesKey);
      if (!_live(gen)) return;
      state = ChapterList(chapters: list, fetchedAt: DateTime.now());
      ref.read(onlineProvider.notifier).state = true;
      unawaited(ChapterCache.write(link.sourceId, link.seriesKey, list));
      // More chapters out than we knew: the library shows them as new.
      double? newest;
      for (final c in list) {
        final n = c.number;
        if (n != null && (newest == null || n > newest)) newest = n;
      }
      if (newest != null) {
        unawaited(ref
            .read(entriesProvider.notifier)
            .noteLatestFromReader(entryId, newest.floor()));
      }
    } catch (e) {
      if (!_live(gen)) return;
      final err = sourceError(e, link.sourceName);
      if (err.offline) ref.read(onlineProvider.notifier).state = false;
      if (state.chapters.isNotEmpty && !state.downloadedOnly) {
        state = state.copyWith(loading: false, error: err);
      } else {
        // No saved list: offer whatever is downloaded.
        final downloaded = ref.read(downloadsProvider).forEntry(entryId)
          ..sort((a, b) => (b.chapter.number ?? 0).compareTo(a.chapter.number ?? 0));
        state = ChapterList(
          chapters: [for (final d in downloaded) d.chapter],
          error: err,
          downloadedOnly: downloaded.isNotEmpty,
        );
      }
    }
  }

  /// Waits until there's a list to work with: the saved copy, a fresh one,
  /// or an error.
  Future<ChapterList> ready() async {
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (ref.mounted && DateTime.now().isBefore(end)) {
      final s = state;
      if (s.chapters.isNotEmpty || !s.loading) return s;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return state;
  }
}

final chaptersProvider =
    NotifierProvider.family<ChaptersNotifier, ChapterList, String>(
        ChaptersNotifier.new);

// ---------------------------------------------------------------------------
// Resume
// ---------------------------------------------------------------------------

class ResumeTarget {
  const ResumeTarget(this.order, this.index, this.page,
      {this.offset = 0, this.caughtUp = false});

  /// Oldest-first chapters the reader moves through (scanlator filter
  /// applied, one release per chapter number).
  final List<ChapterInfo> order;
  final int index;

  /// 0-based page to open at, and how far down it (0..1).
  final int page;
  final double offset;

  /// Every chapter is read; [index] is the last one.
  final bool caughtUp;

  ChapterInfo get chapter => order[index];
}

/// Where Resume opens: the chapter and page you stopped at; the next
/// chapter if you finished it; otherwise the first chapter after the one
/// your library says you're on (or the very first, if you haven't started).
ResumeTarget? resolveResume(Entry e, ReadingLink link, List<ChapterInfo> all) {
  final order = readingOrder(filterByScanlator(all, link.scanlators),
      preferred: link.lastScanlator);
  if (order.isEmpty) return null;

  final lastN = link.lastChapterNumber;
  // You moved the chapter forward by hand past where the reader stopped.
  final aheadOfReader = lastN != null && e.chapter > lastN.floor();
  if (link.hasProgress && !aheadOfReader) {
    var i = link.lastChapterKey == null
        ? -1
        : order.indexWhere((c) => c.key == link.lastChapterKey);
    if (i < 0 && lastN != null) i = order.indexWhere((c) => c.number == lastN);
    if (i >= 0) {
      if (!link.lastFinished) {
        return ResumeTarget(order, i, link.lastPage,
            offset: link.lastPageOffset);
      }
      if (i + 1 < order.length) return ResumeTarget(order, i + 1, 0);
      return ResumeTarget(order, i, 0, caughtUp: true);
    }
  }
  if (e.chapter <= 0) return ResumeTarget(order, 0, 0);
  final next = order.indexWhere((c) => c.number != null && c.number! > e.chapter);
  if (next >= 0) return ResumeTarget(order, next, 0);
  return ResumeTarget(order, order.length - 1, 0, caughtUp: true);
}

// ---------------------------------------------------------------------------
// The main read button
// ---------------------------------------------------------------------------

/// "Ch. 12", "Ch. 12.5", or the chapter's name when it has no number.
String chapterButtonLabel(ChapterInfo c) {
  final n = c.number;
  if (n == null) return c.name;
  return n == n.roundToDouble() ? 'Ch. ${n.toInt()}' : 'Ch. $n';
}

String _num(double n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n';

/// What the main read button says: "Start Reading" for a title you haven't
/// started, otherwise "Continue Reading: Ch. 12, Page 4" — exactly where
/// Resume will open. Uses [chapters] (the title's chapter list, if loaded)
/// to work out the next chapter after a finished one; without it, falls
/// back to the saved bookmark.
String readButtonLabel(
    Entry e, ReadingLink? link, List<ChapterInfo> chapters) {
  final started = (link?.hasProgress ?? false) || e.chapter > 0;
  if (!started) return 'Start Reading';

  if (link != null && chapters.isNotEmpty) {
    final t = resolveResume(e, link, chapters);
    if (t != null) {
      if (t.caughtUp) return 'Caught up · ${chapterButtonLabel(t.chapter)}';
      return 'Continue Reading: ${chapterButtonLabel(t.chapter)}, '
          'Page ${t.page + 1}';
    }
  }

  // No chapter list yet: go by the bookmark alone.
  final n = link?.lastChapterNumber;
  final aheadOfReader = n != null && e.chapter > n.floor();
  if (link != null && link.hasProgress && !aheadOfReader) {
    if (!link.lastFinished && n != null) {
      return 'Continue Reading: Ch. ${_num(n)}, Page ${link.lastPage + 1}';
    }
    if (n != null) return 'Continue Reading: after Ch. ${_num(n)}';
    return 'Continue Reading';
  }
  return 'Continue Reading: Ch. ${e.chapter + 1}';
}
