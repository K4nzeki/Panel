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
  const MangaDexException(this.message, {this.rateLimited = false});
  final String message;
  final bool rateLimited;
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
      if (!kIsWeb) 'User-Agent': 'Panel (com.readlist.panel)',
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode == 429) {
      throw const MangaDexException('MangaDex is busy — try again shortly.',
          rateLimited: true);
    }
    if (res.statusCode != 200) {
      throw MangaDexException('MangaDex request failed (${res.statusCode}).');
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

    String? cover;
    for (final r in (m['relationships'] as List?) ?? const []) {
      if (r is Map && r['type'] == 'cover_art') {
        final file = (r['attributes'] as Map?)?['fileName'] as String?;
        if (file != null) {
          cover = 'https://uploads.mangadex.org/covers/$id/$file.512.jpg';
        }
      }
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
