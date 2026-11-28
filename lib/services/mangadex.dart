import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A series on MangaDex.
class SourceManga {
  const SourceManga({
    required this.id,
    required this.title,
    this.altTitles = const [],
    this.coverUrl,
    this.status,
    this.year,
  });

  final String id;
  final String title;
  final List<String> altTitles;
  final String? coverUrl;
  final String? status; // ongoing, completed, hiatus, cancelled
  final int? year;

  /// Value stored in `entries.source_id`.
  String get sourceId => '${MangaDexService.prefix}$id';

  SourceManga withCover(String? url) => SourceManga(
        id: id,
        title: title,
        altTitles: altTitles,
        coverUrl: url,
        status: status,
        year: year,
      );

  bool matchesTitle(String other) {
    final k = normalizeTitle(other);
    if (k.isEmpty) return false;
    return normalizeTitle(title) == k ||
        altTitles.any((t) => normalizeTitle(t) == k);
  }
}

/// One chapter in a MangaDex feed.
class MangaDexChapter {
  const MangaDexChapter({
    required this.id,
    this.chapter,
    this.title,
    this.volume,
    this.group,
    this.publishedAt,
  });

  final String id;
  final String? chapter; // "12", "12.5", or null for oneshots
  final String? title;
  final String? volume;
  final String? group;
  final DateTime? publishedAt;
}

/// Lowercase letters and digits only, so "Solo Leveling!" == "solo leveling".
String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-￿]+'), '');

class MangaDexException implements Exception {
  const MangaDexException(this.message,
      {this.rateLimited = false, this.notFound = false});
  final String message;
  final bool rateLimited;

  /// MangaDex has no such series / cover (404).
  final bool notFound;
  @override
  String toString() => message;
}

/// MangaDex's public API (no key needed). Used for accurate covers and for
/// the newest chapter number of a series. Limit is ~5 requests a second;
/// callers space their requests out.
class MangaDexService {
  MangaDexService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const prefix = 'mangadex:';
  static const _api = 'api.mangadex.org';

  /// How Panel names itself to MangaDex. MangaDex asks clients not to
  /// pretend to be a browser, and its image servers may refuse (or answer
  /// with a challenge page) when they see a fake browser User-Agent.
  static const userAgent = 'Panel (com.readlist.panel)';

  /// Where MangaDex cover images live.
  static const coverHost = 'uploads.mangadex.org';

  /// Size of the cover thumbnails Panel shows (MangaDex has 256 and 512).
  static const coverSize = 512;

  /// Headers for MangaDex images (covers). Off the web only: browsers
  /// don't let apps set these.
  static const imageHeaders = {
    'User-Agent': userAgent,
    'Referer': 'https://mangadex.org/',
  };

  /// Whether [host] serves MangaDex images.
  static bool isMangaDexHost(String host) {
    final h = host.toLowerCase();
    return h == 'mangadex.org' || h.endsWith('.mangadex.org');
  }

  /// The cover thumbnail of [mangaId] whose file on MangaDex is [fileName]
  /// (the `cover_art` relationship's `fileName`), or null when either is
  /// missing. MangaDex thumbnails are always `<fileName>.<size>.jpg`, even
  /// for png / webp originals. [size] null = the original file.
  static String? coverUrlFor(String? mangaId, String? fileName,
      {int? size = coverSize}) {
    final id = mangaId?.trim() ?? '';
    var file = fileName?.trim() ?? '';
    if (id.isEmpty || file.isEmpty || file == 'null') return null;
    // A file name that already carries a thumbnail suffix.
    file = file.replaceFirst(RegExp(r'\.(256|512)\.jpg$'), '');
    if (file.isEmpty) return null;
    final path = '/covers/${Uri.encodeComponent(id)}/${Uri.encodeComponent(file)}';
    return 'https://$coverHost$path${size == null ? '' : '.$size.jpg'}';
  }

  /// [url] as a well-formed MangaDex cover of [mangaId], or null when it
  /// can't be one (wrong series, no file name, not a cover link). Fixes
  /// the forms older versions or other apps saved: `http://`, the
  /// `mangadex.org/covers/` path, a doubled or odd size suffix.
  /// Links that aren't on MangaDex at all are returned unchanged (a cover
  /// picked from AniList or a site is fine as it is).
  static String? repairCoverUrl(String? url, String mangaId) {
    final raw = url?.trim() ?? '';
    if (raw.isEmpty) return null;
    final u = Uri.tryParse(raw);
    if (u == null) return null;
    if (!isMangaDexHost(u.host)) return raw;
    final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
    final at = seg.indexOf('covers');
    if (at < 0 || seg.length < at + 3) return null;
    final id = seg[at + 1], file = seg[at + 2];
    if (id != mangaId) return null;
    final base = file.replaceFirst(RegExp(r'(\.(256|512)\.jpg)+$'), '');
    final size = RegExp(r'\.(256|512)\.jpg$').firstMatch(file)?.group(1);
    return coverUrlFor(id, base, size: size == null ? null : int.parse(size));
  }

  /// Whether [url] looks like a cover MangaDex will serve for [mangaId].
  static bool isValidCoverUrl(String? url, String mangaId) {
    final fixed = repairCoverUrl(url, mangaId);
    return fixed != null && fixed == url?.trim();
  }

  /// Chapter language used for "latest chapter".
  static const language = 'en';

  static const _ratings = ['safe', 'suggestive', 'erotica', 'pornographic'];

  static String? idFrom(String? sourceId) =>
      (sourceId != null && sourceId.startsWith(prefix))
          ? sourceId.substring(prefix.length)
          : null;

  Future<List<SourceManga>> search(String title, {int limit = 10}) async {
    final q = title.trim();
    if (q.isEmpty) return const [];
    final json = await _get('/manga', {
      'title': q,
      'limit': '$limit',
      'includes[]': ['cover_art'],
      'contentRating[]': _ratings,
      'order[relevance]': 'desc',
    });
    final data = (json['data'] as List?) ?? const [];
    return data.cast<Map<String, dynamic>>().map(_toManga).toList();
  }

  /// One series by id (for its cover), or null if MangaDex doesn't have it.
  /// When the series' cover comes back without its file name (the
  /// relationship wasn't expanded), the cover is looked up by its own id.
  Future<SourceManga?> manga(String id) async {
    final Map<String, dynamic> json;
    try {
      json = await _get('/manga/$id', {
        'includes[]': ['cover_art'],
      });
    } on MangaDexException catch (e) {
      if (e.notFound) return null;
      rethrow;
    }
    final data = json['data'];
    if (data is! Map) return null;
    final m = _toManga(data.cast<String, dynamic>());
    if (m.coverUrl != null) return m;
    final coverId = coverIdOf(data.cast<String, dynamic>());
    if (coverId == null) return m;
    final file = await _coverFileName(coverId);
    final url = coverUrlFor(m.id, file);
    return url == null ? m : m.withCover(url);
  }

  /// The file name of cover [coverId], or null.
  Future<String?> _coverFileName(String coverId) async {
    try {
      final json = await _get('/cover/$coverId', const {});
      final a = (json['data'] as Map?)?['attributes'];
      final f = a is Map ? a['fileName'] : null;
      return f is String && f.trim().isNotEmpty ? f.trim() : null;
    } on MangaDexException catch (e) {
      if (e.notFound) return null;
      rethrow;
    }
  }

  /// Id of the `cover_art` relationship of a manga object, if any.
  @visibleForTesting
  static String? coverIdOf(Map<String, dynamic> m) {
    for (final r in (m['relationships'] as List?) ?? const []) {
      if (r is Map && r['type'] == 'cover_art' && r['id'] is String) {
        final id = (r['id'] as String).trim();
        if (id.isNotEmpty) return id;
      }
    }
    return null;
  }

  Map<String, String>? _tagIds;

  /// MangaDex's genre / theme tags: [normalizeTag]ged English name → id.
  /// Loaded once per session.
  Future<Map<String, String>> tagIds() async {
    final cached = _tagIds;
    if (cached != null) return cached;
    final json = await _get('/manga/tag', const {});
    final out = <String, String>{};
    for (final t in (json['data'] as List?) ?? const []) {
      if (t is! Map) continue;
      final id = t['id'];
      final names = (t['attributes'] as Map?)?['name'];
      final en = names is Map ? names['en'] : null;
      if (id is String && en is String) out[normalizeTag(en)] = id;
    }
    return _tagIds = out;
  }

  /// "Slice of Life" → "sliceoflife", to match tags and genre names.
  static String normalizeTag(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// A Discover list: series ordered by [order] (a MangaDex order field,
  /// e.g. `followedCount`, `rating`, `relevance`), optionally matching
  /// [query] and having every tag in [tagIds]. Only series with chapters
  /// in [language], and no adult content. [createdSince] keeps only series
  /// added after that time (used for "trending").
  Future<({List<SourceManga> manga, bool hasMore})> browse({
    required String order,
    String query = '',
    List<String> tagIds = const [],
    DateTime? createdSince,
    int offset = 0,
    int limit = 30,
  }) async {
    final q = query.trim();
    String stamp(DateTime d) =>
        d.toUtc().toIso8601String().split('.').first.replaceAll('Z', '');
    final json = await _get('/manga', {
      if (q.isNotEmpty) 'title': q,
      'limit': '$limit',
      'offset': '$offset',
      'includes[]': ['cover_art'],
      'contentRating[]': const ['safe', 'suggestive'],
      'availableTranslatedLanguage[]': const [language],
      'hasAvailableChapters': 'true',
      'order[$order]': 'desc',
      if (tagIds.isNotEmpty) 'includedTags[]': tagIds,
      if (createdSince != null) 'createdAtSince': stamp(createdSince),
    });
    final data = (json['data'] as List?) ?? const [];
    final total = (json['total'] as num?)?.toInt() ?? 0;
    return (
      manga: data.cast<Map<String, dynamic>>().map(_toManga).toList(),
      // MangaDex stops paging at 10 000 results.
      hasMore: offset + data.length < total &&
          offset + limit < 10000 &&
          data.isNotEmpty,
    );
  }

  /// Best match for [title]: an exact (normalised) title or alt-title match,
  /// otherwise null. Exact-only so a wrong series never gets linked silently.
  Future<SourceManga?> findExact(String title) async {
    final results = await search(title);
    for (final r in results) {
      if (r.matchesTitle(title)) return r;
    }
    return null;
  }

  /// Newest chapter number (rounded down: 120.5 → 120), or null if the
  /// series has no chapters in [language].
  Future<int?> latestChapter(String mangaId) async {
    final json = await _get('/manga/$mangaId/aggregate', {
      'translatedLanguage[]': [language],
    });
    return parseLatest(json);
  }

  /// Every readable chapter of [mangaId] in [language], newest first, with
  /// the scanlation group names. Chapters hosted elsewhere (official
  /// publisher links) are left out since they can't be read here.
  Future<List<MangaDexChapter>> chapterFeed(String mangaId,
      {String lang = language}) async {
    const limit = 500;
    final out = <MangaDexChapter>[];
    for (var offset = 0; offset < 10000; offset += limit) {
      final json = await _get('/manga/$mangaId/feed', {
        'translatedLanguage[]': [lang],
        'order[chapter]': 'desc',
        'includes[]': ['scanlation_group'],
        'contentRating[]': _ratings,
        'includeExternalUrl': '0',
        'includeEmptyPages': '0',
        'limit': '$limit',
        'offset': '$offset',
      });
      out.addAll(parseFeed(json));
      final total = (json['total'] as num?)?.toInt() ?? 0;
      if (offset + limit >= total) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return out;
  }

  @visibleForTesting
  static List<MangaDexChapter> parseFeed(Map<String, dynamic> json) {
    final out = <MangaDexChapter>[];
    for (final d in (json['data'] as List?) ?? const []) {
      if (d is! Map) continue;
      final a = (d['attributes'] as Map?) ?? const {};
      if (a['externalUrl'] != null) continue;
      final groups = <String>[
        for (final r in (d['relationships'] as List?) ?? const [])
          if (r is Map && r['type'] == 'scanlation_group')
            if ((r['attributes'] as Map?)?['name'] case final String n) n,
      ];
      out.add(MangaDexChapter(
        id: '${d['id']}',
        chapter: a['chapter'] as String?,
        title: a['title'] as String?,
        volume: a['volume'] as String?,
        group: groups.isEmpty ? null : groups.join(' & '),
        publishedAt: DateTime.tryParse('${a['publishAt'] ?? a['readableAt'] ?? ''}'),
      ));
    }
    return out;
  }

  /// Image URLs of one chapter, in order. MangaDex hands out a fresh image
  /// server each time; the links work for about 15 minutes.
  Future<List<String>> chapterPages(String chapterId) async {
    final json = await _get('/at-home/server/$chapterId', const {});
    final base = json['baseUrl'] as String?;
    final ch = (json['chapter'] as Map?) ?? const {};
    final hash = ch['hash'] as String?;
    final files = (ch['data'] as List?)?.whereType<String>().toList() ?? const [];
    if (base == null || hash == null || files.isEmpty) {
      throw const MangaDexException('This chapter has no pages on MangaDex.');
    }
    return [for (final f in files) '$base/data/$hash/$f'];
  }

  /// Highest chapter number in an `/aggregate` response, rounded down.
  @visibleForTesting
  static int? parseLatest(Map<String, dynamic> json) {
    // "volumes" is a map normally, but an empty list when there are none.
    final volumes = json['volumes'];
    if (volumes is! Map) return null;
    double? best;
    for (final v in volumes.values) {
      final chapters = (v is Map) ? v['chapters'] : null;
      if (chapters is! Map) continue;
      for (final key in chapters.keys) {
        final n = double.tryParse(key.toString());
        if (n != null && (best == null || n > best)) best = n;
      }
    }
    return best?.floor();
  }

  Future<Map<String, dynamic>> _get(
      String path, Map<String, dynamic> params) async {
    final uri = Uri.https(_api, path, params.isEmpty ? null : params);
    final res = await _client.get(uri, headers: {
      'Accept': 'application/json',
      // MangaDex asks API clients to identify themselves (browsers can't).
      if (!kIsWeb) 'User-Agent': userAgent,
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode == 429) {
      throw const MangaDexException('MangaDex is busy — try again shortly.',
          rateLimited: true);
    }
    if (res.statusCode != 200) {
      throw MangaDexException('MangaDex request failed (${res.statusCode}).',
          notFound: res.statusCode == 404);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @visibleForTesting
  static SourceManga parseManga(Map<String, dynamic> m) => _toManga(m);

  static SourceManga _toManga(Map<String, dynamic> m) {
    final id = m['id'] as String;
    final a = (m['attributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final titles = (a['title'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alts = <String>[
      for (final t in (a['altTitles'] as List?) ?? const [])
        if (t is Map) ...t.values.whereType<String>(),
    ];
    final title = (titles['en'] as String?) ??
        titles.values.whereType<String>().firstOrNull ??
        alts.firstOrNull ??
        'Untitled';

    // The first cover_art relationship with a file name is the main cover.
    String? cover;
    for (final r in (m['relationships'] as List?) ?? const []) {
      if (r is! Map || r['type'] != 'cover_art') continue;
      final file = (r['attributes'] as Map?)?['fileName'];
      cover = coverUrlFor(id, file is String ? file : null);
      if (cover != null) break;
    }
    return SourceManga(
      id: id,
      title: title,
      altTitles: [...titles.values.whereType<String>(), ...alts],
      coverUrl: cover,
      status: a['status'] as String?,
      year: (a['year'] as num?)?.toInt(),
    );
  }
}
