import '../../models/reader.dart';

/// Somewhere Panel can read chapters from.
///
/// Panel can't run Mihon / Tachiyomi extension code (those are Android
/// apps built for Mihon's runtime). Instead it has its own small readers:
/// MangaDex through its public API, and website sources (the sites listed
/// by your extension repos) read directly when they use one of the common
/// manga site themes (Madara, MangaThemesia). See [SiteSource].
abstract class ReaderSource {
  /// Stable id saved with each title: `mangadex`, or `site:<origin>`.
  String get id;
  String get name;
  String get lang;

  /// Headers images need (some sites refuse images without a Referer).
  Map<String, String> get imageHeaders;

  Future<List<SourceSeries>> search(String query);

  /// Newest first.
  Future<List<ChapterInfo>> chapters(String seriesKey);

  /// Image URLs, in reading order.
  Future<List<String>> pages(ChapterInfo chapter);
}

/// A friendly message about a source that didn't work.
class SourceException implements Exception {
  const SourceException(this.message, {this.offline = false});
  final String message;

  /// The phone has no connection (as opposed to the site misbehaving).
  final bool offline;

  @override
  String toString() => message;
}

/// Turns low-level errors (sockets, timeouts) into a [SourceException].
SourceException sourceError(Object e, String sourceName) {
  if (e is SourceException) return e;
  final s = e.toString();
  if (s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('ClientException') ||
      s.contains('HandshakeException')) {
    return const SourceException(
        "You're offline. Downloaded chapters still work.",
        offline: true);
  }
  if (s.contains('TimeoutException')) {
    return SourceException('$sourceName is taking too long. Try again.');
  }
  return SourceException('$sourceName: ${s.replaceFirst('Exception: ', '')}');
}
