import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/reader.dart';
import 'package:panel/screens/discover_source_browser.dart';
import 'package:panel/services/mangadex.dart';
import 'package:panel/services/sources/apk_source.dart';
import 'package:panel/services/sources/mangadex_source.dart';
import 'package:panel/services/sources/reader_source.dart';
import 'package:panel/services/sources/site_source.dart';
import 'package:panel/state/providers.dart';
import 'package:panel/state/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChapterInfo ch(String key, double n) =>
    ChapterInfo(key: key, name: 'Chapter $n', number: n);

Future<ProviderContainer> container([Map<String, Object> saved = const {}]) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('favorite chapters', () {
    test('filter keeps the list order', () {
      final list = [ch('a', 1), ch('b', 2), ch('c', 3)];
      expect(filterFavorites(list, {'c', 'a'}).map((c) => c.key), ['a', 'c']);
      expect(filterFavorites(list, const {}), isEmpty);
    });

    test('toggle on and off, per title, and saved on the phone', () async {
      final c = await container();
      final favs = c.read(favoriteChaptersProvider.notifier);
      expect(favs.toggle('e1', 'c1'), isTrue);
      expect(favs.isFavorite('e1', 'c1'), isTrue);
      expect(favs.isFavorite('e2', 'c1'), isFalse);

      final saved = c.read(sharedPrefsProvider).getString('favorite_chapters_v1')!;
      final again = await container({'favorite_chapters_v1': saved});
      expect(again.read(favoriteChaptersProvider), {
        'e1': {'c1'}
      });

      expect(favs.toggle('e1', 'c1'), isFalse);
      expect(c.read(favoriteChaptersProvider), isEmpty);
    });

    test('ignores unreadable saved data', () async {
      final c = await container({'favorite_chapters_v1': 'nope'});
      expect(c.read(favoriteChaptersProvider), isEmpty);
    });
  });

  group('extension filters for Discover', () {
    final filters = <Map<Object?, Object?>>[
      {'type': 'header', 'name': 'Note'},
      {
        'type': 'sort',
        'name': 'Sort by',
        'values': ['Latest', 'Popular', 'Rating'],
        'state': null,
      },
      {
        'type': 'group',
        'name': 'Genres',
        'filters': [
          {'type': 'tristate', 'name': 'Action', 'state': 0},
          {'type': 'tristate', 'name': 'Slice of Life', 'state': 0},
        ],
      },
    ];

    test('picks the genre and the order', () {
      final st = ApkSource.filterStates(filters,
          genre: 'Slice of Life', sort: BrowseSort.top);
      expect(st.genre, isTrue);
      expect(st.sort, isTrue);
      expect(st.states[0], isNull);
      expect(st.states[1], {'index': 2, 'ascending': false});
      expect(st.states[2], [null, 1]);
    });

    test('says when a genre or order is not available', () {
      final st = ApkSource.filterStates(filters, genre: 'Cooking');
      expect(st.genre, isFalse);
      expect(st.states.every((s) => s == null), isTrue);
      expect(ApkSource.filterStates(const [], sort: BrowseSort.top).sort,
          isFalse);
    });

    test('genre from a select filter', () {
      final st = ApkSource.filterStates([
        {
          'type': 'select',
          'name': 'Genre',
          'values': ['All', 'Action', 'Romance'],
          'state': 0,
        },
      ], genre: 'romance');
      expect(st.genre, isTrue);
      expect(st.states, [2]);
    });

    test('sort options by name', () {
      const values = ['Most views', 'Hot', 'Top rated'];
      expect(ApkSource.sortIndex(values, BrowseSort.popular), 0);
      expect(ApkSource.sortIndex(values, BrowseSort.trending), 1);
      expect(ApkSource.sortIndex(values, BrowseSort.top), 2);
      expect(ApkSource.sortIndex(const ['A–Z'], BrowseSort.top), -1);
    });
  });

  group('website lists', () {
    test('Madara list, genre and search urls', () {
      expect(
          SiteSource.madaraListUrl('https://x.com', BrowseSort.trending)
              .toString(),
          'https://x.com/manga/?m_orderby=trending');
      expect(
          SiteSource.madaraListUrl('https://x.com', BrowseSort.top,
                  page: 2, genre: 'slice-of-life')
              .toString(),
          'https://x.com/manga-genre/slice-of-life/page/2/?m_orderby=rating');
      final search = SiteSource.madaraListUrl('https://x.com', BrowseSort.popular,
          query: 'solo', genre: 'action');
      expect(search.queryParameters['s'], 'solo');
      expect(search.queryParameters['m_orderby'], 'views');
      expect(search.queryParameters['genre[]'], 'action');
    });

    test('MangaThemesia list url', () {
      final u = SiteSource.themesiaListUrl('https://y.org', BrowseSort.popular,
          page: 3, genre: 'action');
      expect(u.path, '/manga/');
      expect(u.queryParameters,
          {'page': '3', 'order': 'popular', 'genre[]': 'action'});
    });

    test('genre slugs', () {
      expect(SiteSource.genreSlug('Slice of Life'), 'slice-of-life');
      expect(SiteSource.genreSlug('Sci-Fi'), 'sci-fi');
    });
  });

  test('all-source results take turns and skip titles seen already', () {
    final md = MangaDexSource(MangaDexService());
    final site = SiteSource(name: 'Site', lang: 'en', baseUrl: 'https://s.com');
    SourceSeries s(String t) => SourceSeries(key: t, title: t);
    final seen = <String>{};
    final hits = interleaveHits([
      (md, [s('A'), s('B'), s('C')]),
      (site, [s('b'), s('D')]),
    ], seen);
    // "B" and "b" are the same title: only the first one stays.
    expect([for (final h in hits) '${h.source.name}:${h.series.title}'],
        ['MangaDex:A', 'Site:b', 'Site:D', 'MangaDex:C']);
    expect(seen, containsAll(['a', 'b', 'c', 'd']));
  });
}
