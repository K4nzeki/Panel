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
    final uri = Uri.https(_api, path, params);
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
