import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/entry.dart';

enum DiscoverSort {
  trending('TRENDING_DESC', 'Trending'),
  popular('POPULARITY_DESC', 'Popular'),
  topRated('SCORE_DESC', 'Top rated');

  const DiscoverSort(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

class DiscoverPage {
  const DiscoverPage(this.results, this.hasNextPage);
  final List<SearchResult> results;
  final bool hasNextPage;
}

/// AniList's public GraphQL API — no key needed. Covers manga / manhwa /
/// manhua well; it has almost no Western comics, so those stay manual.
class AniListService {
  AniListService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static final _endpoint = Uri.parse('https://graphql.anilist.co');

  static const _mediaFields = '''
    id
    countryOfOrigin
    chapters
    status
    description(asHtml: false)
    averageScore
    title { romaji english }
    coverImage { large medium }
    staff(sort: RELEVANCE, perPage: 1) { edges { node { name { full } } } }
  ''';

  static const _searchQuery = '''
    query (\$search: String) {
      Page(page: 1, perPage: 12) {
        media(search: \$search, type: MANGA, sort: SEARCH_MATCH) { $_mediaFields }
      }
    }
  ''';

  static const _discoverQuery = '''
    query (\$page: Int, \$sort: [MediaSort], \$country: CountryCode) {
      Page(page: \$page, perPage: 24) {
        pageInfo { hasNextPage }
        media(type: MANGA, sort: \$sort, format_in: [MANGA, ONE_SHOT], countryOfOrigin: \$country) {
          $_mediaFields
        }
      }
    }
  ''';

  Future<List<SearchResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = await _post(_searchQuery, {'search': q});
    final media = (data['Page']?['media'] as List?) ?? const [];
    return media.cast<Map<String, dynamic>>().map(_toResult).toList();
  }

  /// [type] narrows to Manga (JP), Manhwa (KR) or Manhua (CN). Comic has no
  /// AniList equivalent, so it's treated as "all".
  Future<DiscoverPage> discover(DiscoverSort sort, int page,
      {EntryType? type}) async {
    final country = switch (type) {
      EntryType.manga => 'JP',
      EntryType.manhwa => 'KR',
      EntryType.manhua => 'CN',
      _ => null,
    };
    final data = await _post(_discoverQuery, {
      'page': page,
      'sort': [sort.apiValue],
      if (country != null) 'country': country,
    });
    final media = (data['Page']?['media'] as List?) ?? const [];
    final hasNext = (data['Page']?['pageInfo']?['hasNextPage'] as bool?) ?? false;
    return DiscoverPage(
      media.cast<Map<String, dynamic>>().map(_toResult).toList(),
      hasNext,
    );
  }

  /// Best match for a title (exact title match preferred), or null.
  Future<SearchResult?> findMatch(String title) async {
    try {
      final results = await search(title);
      if (results.isEmpty) return null;
      final t = title.trim().toLowerCase();
      return results.firstWhere(
            (r) => r.title.trim().toLowerCase() == t,
        orElse: () => results.first,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _post(
      String query, Map<String, dynamic> variables) async {
    final res = await _client
        .post(
      _endpoint,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({'query': query, 'variables': variables}),
    )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 429) {
      throw const AniListException('AniList is busy — try again in a minute.');
    }
    if (res.statusCode != 200) {
      throw AniListException('Search failed (${res.statusCode}).');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['data'] as Map<String, dynamic>?) ?? const {};
  }

  static SearchResult _toResult(Map<String, dynamic> m) {
    final title = m['title'] as Map<String, dynamic>?;
    final cover = m['coverImage'] as Map<String, dynamic>?;
    final edges = (m['staff']?['edges'] as List?) ?? const [];
    final author = edges.isNotEmpty
        ? (edges.first['node']?['name']?['full'] as String?)
        : null;
    return SearchResult(
      id: m['id'].toString(),
      title: (title?['english'] as String?) ??
          (title?['romaji'] as String?) ??
          'Untitled',
      type: _typeFromCountry(m['countryOfOrigin'] as String?),
      author: author,
      coverUrl: (cover?['large'] as String?) ?? (cover?['medium'] as String?),
      totalChapters: (m['chapters'] as num?)?.toInt(),
      publicationStatus: _statusLabel(m['status'] as String?),
      description: _stripHtml(m['description'] as String?),
      averageScore: (m['averageScore'] as num?)?.toInt(),
    );
  }

  static EntryType _typeFromCountry(String? c) => switch (c) {
    'KR' => EntryType.manhwa,
    'CN' || 'TW' => EntryType.manhua,
    _ => EntryType.manga,
  };

  static String? _statusLabel(String? s) => switch (s) {
    null => null,
    'RELEASING' => 'Ongoing',
    'FINISHED' => 'Completed',
    'NOT_YET_RELEASED' => 'Upcoming',
    'CANCELLED' => 'Cancelled',
    'HIATUS' => 'Hiatus',
    _ => s,
  };

  static String? _stripHtml(String? html) {
    if (html == null) return null;
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#039;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class AniListException implements Exception {
  const AniListException(this.message);
  final String message;
  @override
  String toString() => message;
}