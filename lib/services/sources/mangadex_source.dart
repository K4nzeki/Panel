import '../../models/reader.dart';
import '../mangadex.dart';
import 'reader_source.dart';

/// MangaDex: official API, English chapters, real scanlation group names.
class MangaDexSource implements ReaderSource {
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
      return [
        for (final m in results)
          SourceSeries(
            key: m.id,
            title: m.title,
            coverUrl: m.coverUrl,
            url: 'https://mangadex.org/title/${m.id}',
            subtitle: [
              if (m.status != null) m.status!,
              if (m.year != null) '${m.year}',
            ].join(' · '),
          ),
      ];
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

  static String _name(MangaDexChapter c) {
    final title = c.title?.trim() ?? '';
    final head = c.chapter == null ? 'Oneshot' : 'Chapter ${c.chapter}';
    return title.isEmpty ? head : '$head: $title';
  }

  SourceException _wrap(Object e) =>
      e is MangaDexException ? SourceException(e.message) : sourceError(e, name);
}
