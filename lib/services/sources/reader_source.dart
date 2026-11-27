import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';

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

/// The quick lists every source can show in Discover.
enum BrowseSort {
  trending('Trending'),
  popular('Popular'),
  top('Top');

  const BrowseSort(this.label);
  final String label;
}

/// Genres offered as a Discover filter. Each source matches them against
/// its own genre / tag names (case and punctuation don't matter).
const browseGenres = [
  'Action',
  'Adventure',
  'Comedy',
  'Drama',
  'Fantasy',
  'Horror',
  'Isekai',
  'Martial Arts',
  'Mystery',
  'Psychological',
  'Romance',
  'School Life',
  'Sci-Fi',
  'Slice of Life',
  'Sports',
  'Supernatural',
  'Thriller',
  'Tragedy',
];

/// "Slice of Life" == "slice-of-life" == "Slice of life".
String genreKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// One page of a Discover list.
class BrowsePage {
  const BrowsePage(this.series,
      {this.hasNextPage = false, this.genreApplied = true});

  final List<SourceSeries> series;
  final bool hasNextPage;

  /// False when a genre was asked for but this source has no way to filter
  /// by it (the list is then unfiltered, and Discover leaves it out).
  final bool genreApplied;
}

/// A source Discover can list: [BrowseSort] lists, search, and a genre
/// filter, page by page ([page] starts at 1).
abstract interface class BrowsableSource {
  Future<BrowsePage> browse({
    BrowseSort sort = BrowseSort.popular,
    String query = '',
    String? genre,
    int page = 1,
  });
}

/// A source that can tell the cover of one of its series.
abstract interface class CoverSource {
  /// The cover of [seriesKey] (named [title] in your list), or null.
  Future<String?> seriesCover(String seriesKey, {String? title});
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

/// A source that loads page images itself instead of a plain GET: Mihon
/// extensions, which need their own HTTP client (cookies, interceptors,
/// per-page headers). The reader and downloads check for this.
abstract interface class ImageFetcher {
  /// Same as [ReaderSource.id]; keys the image cache.
  String get id;

  /// [url] is one of the strings [ReaderSource.pages] returned.
  Future<FetchedImage> fetchImage(String url);
}

class FetchedImage {
  const FetchedImage(this.bytes, {this.contentType});
  final Uint8List bytes;

  /// e.g. `image/webp`, when the server said.
  final String? contentType;
}

/// Shows an image from an [ImageFetcher] (like NetworkImage does for URLs).
/// [attempt] is part of the key so "Retry" really loads it again.
class FetchedImageProvider extends ImageProvider<FetchedImageProvider> {
  const FetchedImageProvider(this.url, this.fetcher, {this.attempt = 0});

  final String url;
  final ImageFetcher fetcher;
  final int attempt;

  @override
  Future<FetchedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<FetchedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
          FetchedImageProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1.0,
        debugLabel: 'FetchedImage',
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final image = await fetcher.fetchImage(url);
    if (image.bytes.isEmpty) throw const SourceException('Empty image');
    return decode(await ui.ImmutableBuffer.fromUint8List(image.bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is FetchedImageProvider &&
      other.url == url &&
      other.attempt == attempt &&
      other.fetcher.id == fetcher.id;

  @override
  int get hashCode => Object.hash(url, attempt, fetcher.id);
}
