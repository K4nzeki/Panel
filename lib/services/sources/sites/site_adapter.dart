import '../../../models/reader.dart';
import '../site_source.dart';
import 'weeb_central.dart';

/// A reader written for one particular site, for sites that are built
/// their own way instead of on a common theme (Madara, MangaThemesia).
///
/// To add a site: write a class like [WeebCentral], then add its host to
/// [forUrl].
abstract class SiteAdapter {
  const SiteAdapter();

  Future<List<SourceSeries>> search(SiteSource site, String query);

  /// Newest first.
  Future<List<ChapterInfo>> chapters(SiteSource site, String seriesKey);

  /// Image URLs, in reading order.
  Future<List<String>> pages(SiteSource site, ChapterInfo chapter);

  /// The adapter for a site, or null when the theme readers should be used.
  static SiteAdapter? forUrl(String url) {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    bool isHost(String h) => host == h || host.endsWith('.$h');
    if (isHost('weebcentral.com')) return const WeebCentral();
    return null;
  }
}
