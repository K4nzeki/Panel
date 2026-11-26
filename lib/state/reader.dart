import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/chapter_cache.dart';
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
  }) : _byId = {
          for (final s in [...installed, ...available]) s.id: s,
        };

  final MangaDexSource mangadex;

  /// Sites of the extensions installed on the phone.
  final List<SiteSource> installed;

  /// Other (non-18+) sites listed by your repos, not installed.
  final List<SiteSource> available;

  final Map<String, SiteSource> _byId;

  /// Searched together when picking a source for a title.
  List<ReaderSource> get primary => [mangadex, ...installed];

  /// The source a title is linked to. Works even if the extension was
  /// uninstalled or the repos can't be reached: the link remembers the site.
  ReaderSource forLink(ReadingLink l) {
    if (l.sourceId == MangaDexSource.sourceId) return mangadex;
    final known = _byId[l.sourceId];
    if (known != null) return known;
    final base = l.sourceBaseUrl ?? l.sourceId.replaceFirst('site:', '');
    return SiteSource(name: l.sourceName, lang: l.sourceLang, baseUrl: base);
  }
}

final readerSourcesProvider = Provider<ReaderSourceRegistry>((ref) {
  // Only rebuild when repos or installed apps change (not on APK progress).
  ref.watch(extensionStoreProvider
      .select((s) => (s.repoUrls, s.repos, s.installed)));
  final store = ref.read(extensionStoreProvider);
  final seen = <String>{};
  final installed = <SiteSource>[];
  final available = <SiteSource>[];
  for (final e in store.extensions) {
    final isInstalled = store.isInstalled(e);
    if (!isInstalled && e.isNsfw) continue;
    for (final s in e.sources) {
      // MangaDex is built in (through its API).
      if (s.baseUrl.contains('mangadex.org')) continue;
      final src = SiteSource.fromExt(s);
      if (!seen.add(src.id)) continue;
      (isInstalled ? installed : available).add(src);
    }
  }
  int rank(SiteSource s) => switch (s.lang) { 'en' => 0, 'all' => 1, _ => 2 };
  int order(SiteSource a, SiteSource b) {
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
    final base = source is SiteSource ? source.base : null;
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

  /// Where you are in the reader. [finished] = you reached the last page.
  void saveProgress(String entryId, ChapterInfo chapter,
      {required int page, int? pageCount, bool finished = false}) {
    final l = state[entryId];
    if (l == null) return;
    final sameChapter = l.lastChapterKey == chapter.key;
    _put(
      entryId,
      l.copyWith(
        lastChapterKey: chapter.key,
        lastChapterNumber: chapter.number,
        lastScanlator: chapter.scanlatorLabel,
        lastPage: page,
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
  const ResumeTarget(this.order, this.index, this.page, {this.caughtUp = false});

  /// Oldest-first chapters the reader moves through (scanlator filter
  /// applied, one release per chapter number).
  final List<ChapterInfo> order;
  final int index;
  final int page;

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
      if (!link.lastFinished) return ResumeTarget(order, i, link.lastPage);
      if (i + 1 < order.length) return ResumeTarget(order, i + 1, 0);
      return ResumeTarget(order, i, 0, caughtUp: true);
    }
  }
  if (e.chapter <= 0) return ResumeTarget(order, 0, 0);
  final next = order.indexWhere((c) => c.number != null && c.number! > e.chapter);
  if (next >= 0) return ResumeTarget(order, next, 0);
  return ResumeTarget(order, order.length - 1, 0, caughtUp: true);
}
