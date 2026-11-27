import '../../models/reader.dart';
import '../mangadex.dart';
import 'reader_source.dart';

/// MangaDex: official API, English chapters, real scanlation group names.
class MangaDexSource implements ReaderSource, BrowsableSource, CoverSource {
  MangaDexSource(this._api);

  final MangaDexService _api;

  static const sourceId = 'mangadex';

  @override
  String get id => sourceId;
  @override
  String get name => 'MangaDex';
  @override
  String get lang => MangaDexService.language;
  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<List<SourceSeries>> search(String query) async {
    try {
      final results = await _api.search(query, limit: 20);
      return [for (final m in results) _series(m)];
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<ChapterInfo>> chapters(String seriesKey) async {
    try {
      final feed = await _api.chapterFeed(seriesKey);
      return [
        for (final c in feed)
          ChapterInfo(
            key: c.id,
            name: _name(c),
            number: c.chapter == null ? null : double.tryParse(c.chapter!),
            scanlator: c.group ?? 'No group',
            uploadedAt: c.publishedAt,
            url: 'https://mangadex.org/chapter/${c.id}',
          ),
      ];
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<String>> pages(ChapterInfo chapter) async {
    try {
      return await _api.chapterPages(chapter.key);
    } catch (e) {
      throw _wrap(e);
    }
  }

  static const _pageSize = 30;

  @override
  Future<BrowsePage> browse({
    BrowseSort sort = BrowseSort.popular,
    String query = '',
    String? genre,
    int page = 1,
  }) async {
    try {
      final searching = query.trim().isNotEmpty;
      var tags = const <String>[];
      var genreApplied = true;
      if (genre != null) {
        final id = (await _api.tagIds())[MangaDexService.normalizeTag(genre)];
        if (id == null) {
          genreApplied = false;
        } else {
          tags = [id];
        }
      }
      final res = await _api.browse(
        order: switch (sort) {
          // A search is best by relevance; "trending" has no meaning there.
          BrowseSort.trending when searching => 'relevance',
          BrowseSort.trending || BrowseSort.popular => 'followedCount',
          BrowseSort.top => 'rating',
        },
        query: query,
        tagIds: tags,
        // MangaDex has no trending list: the most followed series added
        // in the last six months is the closest thing.
        createdSince: sort == BrowseSort.trending && !searching
            ? DateTime.now().subtract(const Duration(days: 182))
            : null,
        offset: (page - 1) * _pageSize,
        limit: _pageSize,
      );
      return BrowsePage(
        [for (final m in res.manga) _series(m)],
        hasNextPage: res.hasMore,
        genreApplied: genreApplied,
      );
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<String?> seriesCover(String seriesKey, {String? title}) async {
    try {
      return (await _api.manga(seriesKey))?.coverUrl;
    } catch (e) {
      throw _wrap(e);
    }
  }

  static SourceSeries _series(SourceManga m) => SourceSeries(
        key: m.id,
        title: m.title,
        coverUrl: m.coverUrl,
        url: 'https://mangadex.org/title/${m.id}',
        subtitle: [
          if (m.status != null) m.status!,
          if (m.year != null) '${m.year}',
        ].join(' · '),
      );

  static String _name(MangaDexChapter c) {
    final title = c.title?.trim() ?? '';
    final head = c.chapter == null ? 'Oneshot' : 'Chapter ${c.chapter}';
    return title.isEmpty ? head : '$head: $title';
  }

  SourceException _wrap(Object e) =>
      e is MangaDexException ? SourceException(e.message) : sourceError(e, name);
}
