import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/chapter_cache.dart';
import '../services/downloads.dart';
import '../services/page_cache.dart';
import '../services/page_prefetcher.dart';
import '../services/sources/reader_source.dart';
import '../state/downloads.dart';
import '../state/providers.dart';
import '../state/reader.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// One page: a downloaded file, or an image on the source.
class _Page {
  const _Page.file(String this.file) : url = null;
  const _Page.net(String this.url) : file = null;
  final String? file;
  final String? url;

  /// Same for the same image (remembered sizes are kept by this).
  String get id => file ?? url!;
}

/// One chapter loaded in the reader. In the long strip several follow one
/// another (continuous scrolling); paged modes show one at a time.
class _Segment {
  _Segment(this.index, this.chapter, this.pages, {required this.fromDownload})
      : keys = List.generate(pages.length, (_) => GlobalKey()),
        endKey = GlobalKey();

  /// Position in the reader's chapter order.
  final int index;
  final ChapterInfo chapter;
  final List<_Page> pages;

  /// One per page, to find where each page is on screen.
  final List<GlobalKey> keys;

  /// The marker after the last page (the break into the next chapter, or
  /// the end of the strip). Seeing it means the chapter was read to the end.
  final GlobalKey endKey;
  final bool fromDownload;

  /// Read to the end during this session (recorded once).
  bool finished = false;

  Iterable<String> get urls => [for (final p in pages) if (p.url != null) p.url!];
}

/// What one row of the long strip shows.
enum _RowKind { head, page, divider, tail }

class _Row {
  const _Row(this.kind, [this.seg, this.page = 0, this.next]);
  final _RowKind kind;
  final _Segment? seg;
  final int page;

  /// The chapter after [seg] (dividers only).
  final _Segment? next;
}

/// Reads a chapter in the title's [ReadingMode]: one page at a time (right
/// to left or left to right) or as one long strip top to bottom. Downloaded
/// chapters open from the phone with no connection. Remembers the page
/// you're on, marks the chapter read when you reach the end, and moves on
/// through [order] (oldest first, scanlator filter applied). Tap the middle
/// to show or hide the controls; in paged modes tap the sides (or use the
/// arrow keys) to turn pages.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.entryId,
    required this.order,
    required this.index,
    this.startPage = 0,
    this.startOffset = 0,
  });

  final String entryId;
  final List<ChapterInfo> order;
  final int index;
  final int startPage;

  /// How far down [startPage] to open, 0..1 (the saved spot on resume).
  final double startOffset;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  /// Most chapters kept loaded in the long strip at once (when the extra
  /// ones can be dropped without moving the screen, see [ChapterStrip]).
  static const _maxStripChapters = 3;

  /// A strip this long (you kept reading chapter after chapter downwards,
  /// where nothing can be dropped) starts over on the chapter you're in.
  static const _restartStripAt = 20;

  /// Pages of the next / previous chapter loaded ahead of time.
  static const _edgePages = 4;

  late int _index = widget.index.clamp(0, widget.order.length - 1);
  late int _startPage = widget.startPage;
  late double _startOffset = widget.startOffset;
  late final ReadingLinksNotifier _links;
  late final ReadChaptersNotifier _readChapters;
  AppLifecycleListener? _lifecycle;

  /// Layout in use; follows [readingModeProvider] (your pick, or the
  /// title type's default).
  late ReadingMode _mode;

  /// Paged modes: the page view's controller (a new one per chapter / mode,
  /// so it opens on the right page).
  PageController? _pager;
  final _focus = FocusNode(debugLabel: 'reader');

  // keepScrollOffset: false — otherwise a new strip reopens at the old
  // strip's scroll offset (PageStorage), often right at the end, and the
  // first scroll marked a chapter you never read as finished.
  final _scroll = ScrollController(keepScrollOffset: false);

  /// The chapter you're reading (in the long strip: the one at the reading
  /// line, 40% down the screen). [_pages] and [_keys] are its pages.
  _Segment? _active;
  List<_Page>? _pages;
  List<GlobalKey> _keys = const [];

  /// Long strip: the chapters loaded one after another.
  final _strip = ChapterStrip<_Segment>(maxChapters: _maxStripChapters);

  /// A new number = a new strip (and a fresh scroll position).
  int _stripGen = 0;
  static const _centerKey = ValueKey<String>('strip-center');

  /// Loading / failure of the chapter after the strip's last one, and the
  /// one before its first. [_nextSkip] / [_prevSkip] skip chapters that
  /// failed ("Skip this chapter").
  bool _loadingNext = false, _loadingPrev = false;
  String? _nextError, _prevError;
  int _nextSkip = 0, _prevSkip = 0;

  /// Page lists of nearby chapters, fetched ahead of time.
  final _pageLists = ChapterPagesCache();

  /// The first pages of the next chapter and the last of the previous one,
  /// loading ahead of time (by chapter position).
  final _edgePrefetch = <int, PagePrefetcher>{};

  /// Height / width of pages already seen, so a page shown again (or still
  /// loading) keeps its real height instead of a guess: nothing jumps.
  final _aspects = <String, double>{};

  /// Top of the strip on screen (from the last scroll).
  double _viewportTop = 0;
  Map<String, String> _headers = const {};

  /// Set for extension sources: they load their own images.
  ImageFetcher? _fetcher;

  /// Page images of this reading session, downloaded once and shared by the
  /// page on screen and the background prefetch. Deleted when you leave.
  final _pageCache = PageCache(dir: _pageCacheDir());
  final _http = http.Client();

  /// Loads every page of the open chapter in the background.
  PagePrefetcher? _prefetch;

  /// Decoded pages ahead of the one you're on (the rest stay encoded, so a
  /// long chapter doesn't fill memory).
  static const _decodeAhead = 3;
  String? _error;
  bool _offline = false;
  bool _fromDownload = false;
  int _page = 0;

  /// How far down [_page] you are, 0..1.
  double _pageOffset = 0;
  bool _ui = true;
  bool _finished = false;
  bool _settling = false;
  int _gen = 0;
  Timer? _saveTimer;

  /// Last position written, so tiny scrolls don't trigger writes.
  int _savedPage = -1;
  double _savedOffset = -1;
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);

  ChapterInfo get _chapter => widget.order[_index];
  bool get _hasNext => _index + 1 < widget.order.length;
  bool get _hasPrev => _index > 0;

  /// Long strip with continuous scrolling on.
  bool get _continuous => !_mode.paged && ref.read(continuousScrollProvider);

  @override
  void initState() {
    super.initState();
    // Kept for dispose(), where ref can't be used any more.
    _links = ref.read(readingLinksProvider.notifier);
    _readChapters = ref.read(readChaptersProvider.notifier);
    _mode = ref.read(readingModeProvider(widget.entryId));
    // Picked in reader settings (or the library loaded the title's type).
    ref.listenManual(readingModeProvider(widget.entryId),
        (_, next) => _applyMode(next));
    // Continuous scrolling turned on or off: rebuild the strip around the
    // chapter you're in.
    ref.listenManual(continuousScrollProvider, (_, _) {
      if (mounted && !_mode.paged && _active != null) _restartStrip();
    });
    // Leaving the app (home button, app switcher, screen off, being killed):
    // write the spot right away instead of waiting for the debounce.
    _lifecycle = AppLifecycleListener(
      onInactive: _flush,
      onHide: _flush,
      onPause: _flush,
      onDetach: _flush,
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    // After the first frame: loading saves progress, which updates providers
    // (not allowed while the widget tree is being built).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _saveTimer?.cancel();
    // Providers can't change while the tree is being torn down: save right
    // after this frame instead.
    _save(later: true);
    _prefetch?.cancel();
    _cancelEdgePrefetch();
    for (final seg in _strip.all) {
      _evictDecoded(seg.pages);
    }
    if (_active != null && !_strip.all.contains(_active)) {
      _evictDecoded(_active!.pages);
    }
    _pageLists.clear();
    // Aborts page downloads still running, then drops the saved pages.
    _http.close();
    unawaited(_pageCache.dispose());
    _scroll.dispose();
    _pager?.dispose();
    _focus.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  // ---- Loading ----

  /// A folder of its own for this reading session's pages.
  static Future<Directory?> _pageCacheDir() async {
    if (kIsWeb) return null;
    try {
      final base = await getTemporaryDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}reader_pages'
          '${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}');
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return null; // pages are kept in memory instead
    }
  }

  /// Downloads one page image from the chapter's source.
  Future<Uint8List> _loadPageBytes(String url) async {
    final fetcher = _fetcher;
    if (fetcher != null) return (await fetcher.fetchImage(url)).bytes;
    final res = await _http
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SourceException('Page image failed (${res.statusCode}).');
    }
    return res.bodyBytes;
  }

  /// What [_PageImage] shows for [page], and what the prefetch decodes
  /// ahead of time: the same provider (and size), so a prefetched page
  /// comes straight from the image cache.
  ImageProvider _providerFor(_Page page, int cacheWidth, {int attempt = 0}) {
    final ImageProvider base = page.file != null
        ? FileImage(File(page.file!))
        : CachedPageImage(page.url!, _pageCache, _loadPageBytes,
            attempt: attempt);
    return ResizeImage.resizeIfNeeded(cacheWidth, null, base);
  }

  int _cacheWidth(BuildContext context) => _lastCacheWidth =
      (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context))
          .round();

  /// The decode width last used, to find a chapter's decoded pages again.
  int _lastCacheWidth = 0;

  /// Frees the decoded images of [pages] (a chapter you left).
  void _evictDecoded(List<_Page>? pages) {
    final w = _lastCacheWidth;
    if (pages == null || w <= 0) return;
    for (final p in pages) {
      unawaited(_providerFor(p, w).evict());
    }
  }

  /// Starts loading every page of the chapter that just opened, from
  /// [start] on, in the background. Downloaded chapters are already on the
  /// phone, so only the pages near you are decoded ([_precacheAround]).
  void _startPrefetch(List<_Page> pages, int start) {
    _prefetch?.cancel();
    _prefetch = null;
    _retainNearby();
    final urls = [for (final p in pages) if (p.url != null) p.url!];
    if (urls.isEmpty) return;
    final prefetch = PagePrefetcher(
      count: pages.length,
      start: start,
      load: (i) async {
        final url = pages[i].url;
        if (url != null) await _pageCache.get(url, _loadPageBytes);
      },
    );
    _prefetch = prefetch..start();
  }

  /// Keeps the saved page images of the chapter you're in and the ones
  /// right before and after it (loaded in the strip, or fetched ahead);
  /// drops the rest, so a long session doesn't pile up pages.
  void _retainNearby() {
    final keep = <String>[];
    for (final i in [_index - 1, _index, _index + 1]) {
      final seg = _strip.at(i);
      if (seg != null) {
        keep.addAll(seg.urls);
      } else if (i >= 0 && i < widget.order.length) {
        keep.addAll(_peekPageList(i) ?? const []);
      }
    }
    if (_active != null) keep.addAll(_active!.urls);
    _pageCache.retain(keep);
  }

  // ---- Chapters' page lists ----

  /// The reading source, or null when the title has none.
  ReaderSource? _source() {
    final link = ref.read(readingLinksProvider)[widget.entryId];
    if (link == null) return null;
    final source = ref.read(readerSourcesProvider).forLink(link);
    _headers = source.imageHeaders;
    _fetcher = source is ImageFetcher ? source as ImageFetcher : null;
    return source;
  }

  /// The page urls of chapter [i], if already fetched (no loading).
  List<String>? _peekPageList(int i) {
    final link = ref.read(readingLinksProvider)[widget.entryId];
    if (link == null) return null;
    return _pageLists.peek(link.sourceId, widget.order[i].key);
  }

  /// Chapter [i]'s pages: downloaded files, or the source's images (the
  /// page list fetched ahead of time when there is one). Throws a
  /// [SourceException] with a message fit for the screen.
  Future<_Segment> _fetchSegment(int i) async {
    final ch = widget.order[i];
    try {
      final dl = ref.read(downloadsProvider).find(widget.entryId, ch.key);
      if (dl != null && dl.files.isNotEmpty) {
        return _Segment(i, ch, [for (final p in dl.paths) _Page.file(p)],
            fromDownload: true);
      }
      final source = _source();
      if (source == null) {
        throw const SourceException('Choose a source for this title first.');
      }
      final urls = await _pageLists.get(source.id, ch.key, () => source.pages(ch));
      if (urls.isEmpty) {
        throw const SourceException('This chapter has no pages.');
      }
      return _Segment(i, ch, [for (final u in urls) _Page.net(u)],
          fromDownload: false);
    } catch (e) {
      final err = sourceError(e, 'The source');
      throw err.offline
          ? const SourceException(
              "This chapter isn't downloaded and you're offline.",
              offline: true)
          : err;
    }
  }

  /// Opens chapter [_index] on its own: the first open, Retry, the
  /// chapter buttons, or a new strip. Continuous scrolling then loads the
  /// chapters around it as you scroll.
  Future<void> _load() async {
    final gen = ++_gen;
    // Leaving this chapter (or retrying it): stop loading its pages.
    _prefetch?.cancel();
    _prefetch = null;
    _cancelEdgePrefetch();
    for (final seg in _strip.all) {
      _evictDecoded(seg.pages);
    }
    setState(() {
      _pages = null;
      _active = null;
      _error = null;
      _finished = false;
      _settling = false;
      _page = 0;
      _pageOffset = 0;
      _resetEdges();
    });
    final _Segment seg;
    try {
      seg = await _fetchSegment(_index);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      final err = sourceError(e, 'The source');
      setState(() {
        _offline = err.offline;
        _error = err.message;
      });
      return;
    }
    if (!mounted || gen != _gen) return;
    final pages = seg.pages;
    final start = _startPage.clamp(0, pages.length - 1);
    // A saved offset only applies to the page it was saved on.
    // Paged modes show whole pages, so there's no spot inside one.
    final offset = start == _startPage && !_mode.paged
        ? _startOffset.clamp(0.0, 1.0)
        : 0.0;
    if (_mode.paged) _newPager(start);
    _strip.reset(seg.index, seg);
    setState(() {
      _stripGen++;
      _active = seg;
      _pages = pages;
      _keys = seg.keys;
      _fromDownload = seg.fromDownload;
      _finished = false;
      _page = start;
      _pageOffset = offset.toDouble();
    });
    _save();
    // Starting a To Read title moves it into your library (Reading).
    unawaited(ref.read(entriesProvider.notifier).startReading(widget.entryId));
    // Every page of the chapter starts loading now, from where you opened.
    _startPrefetch(pages, start);
    _precacheAround(start);
    _warmNeighbours();
    if (_mode.paged) {
      // Opening on the last page (or a one-page chapter) is reading it.
      if (start >= pages.length - 1) _markFinished();
    } else {
      if (start > 0 || offset > 0) _jumpTo(start);
      // A short chapter may not fill the screen: carry on into the next.
      WidgetsBinding.instance.addPostFrameCallback((_) => _extendIfNeeded());
    }
  }

  void _resetEdges() {
    _loadingNext = _loadingPrev = false;
    _nextError = _prevError = null;
    _nextSkip = _prevSkip = 0;
  }

  /// Builds the strip again around the chapter and page you're on (after
  /// a mode switch, turning continuous scrolling on or off, or when it got
  /// very long).
  void _restartStrip() {
    if (_active == null) return;
    _saveTimer?.cancel();
    _save();
    _startPage = _page;
    _startOffset = _pageOffset;
    _load();
  }

  /// Gets the chapters before and after the one you're in ready: their
  /// page lists, then the pages you'd see first when scrolling into them
  /// (the next chapter's first pages, the previous one's last).
  void _warmNeighbours() {
    final gen = _gen;
    final wanted = <int>{};
    void warm(int i, {required bool fromEnd}) {
      if (i < 0 || i >= widget.order.length) return;
      wanted.add(i);
      if (_edgePrefetch.containsKey(i)) return;
      final ch = widget.order[i];
      // Downloaded: already on the phone, nothing to fetch.
      if (ref.read(downloadsProvider).find(widget.entryId, ch.key) != null) {
        return;
      }
      final source = _source();
      if (source == null) return;
      _pageLists.get(source.id, ch.key, () => source.pages(ch)).then((urls) {
        // Still next to the chapter you're in (you may have moved on).
        if (!mounted || gen != _gen || (i - _index).abs() != 1 || urls.isEmpty) {
          return;
        }
        if (_edgePrefetch.containsKey(i)) return;
        final p = PagePrefetcher(
          count: urls.length,
          concurrency: 2,
          order: PagePrefetcher.edgeOrder(urls.length,
              fromEnd: fromEnd, limit: _edgePages),
          load: (k) => _pageCache.get(urls[k], _loadPageBytes),
        );
        _edgePrefetch[i] = p..start();
        _retainNearby();
      }, onError: (Object _) {
        // Tried again (and explained) when you actually scroll into it.
      });
    }

    warm(_index + 1, fromEnd: false);
    // Going back is only seamless in the long strip.
    if (!_mode.paged) warm(_index - 1, fromEnd: true);
    // Chapters you moved away from don't need preloading any more.
    for (final k in _edgePrefetch.keys.toList()) {
      if (!wanted.contains(k)) _edgePrefetch.remove(k)!.cancel();
    }
  }

  void _cancelEdgePrefetch() {
    for (final p in _edgePrefetch.values) {
      p.cancel();
    }
    _edgePrefetch.clear();
  }

  // ---- Continuous scrolling ----

  /// Loads the chapter after the strip's last one onto the end.
  Future<void> _appendNext() async {
    final last = _strip.lastIndex;
    if (!_continuous || last == null || _loadingNext || _nextError != null) {
      return;
    }
    final i = last + 1 + _nextSkip;
    if (i >= widget.order.length) return;
    final gen = _gen;
    setState(() => _loadingNext = true);
    try {
      final seg = await _fetchSegment(i);
      if (!mounted || gen != _gen) return;
      setState(() {
        _strip.append(i, seg);
        _loadingNext = false;
        _nextSkip = 0;
      });
      _edgePrefetch.remove(i)?.cancel(); // the strip has it now
      _precacheSegment(seg, fromEnd: false);
      _trimStrip();
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loadingNext = false;
        _nextError = '${widget.order[i].name}: ${friendlyError(e)}';
      });
    }
  }

  /// Loads the chapter before the strip's first one above it. The strip
  /// grows upwards from its anchor, so what's on screen doesn't move.
  Future<void> _prependPrev() async {
    final first = _strip.firstIndex;
    if (!_continuous || first == null || _loadingPrev || _prevError != null) {
      return;
    }
    final i = first - 1 - _prevSkip;
    if (i < 0) return;
    final gen = _gen;
    setState(() => _loadingPrev = true);
    try {
      final seg = await _fetchSegment(i);
      if (!mounted || gen != _gen) return;
      setState(() {
        _strip.prepend(i, seg);
        _loadingPrev = false;
        _prevSkip = 0;
      });
      _edgePrefetch.remove(i)?.cancel();
      _precacheSegment(seg, fromEnd: true);
      _trimStrip();
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loadingPrev = false;
        _prevError = '${widget.order[i].name}: ${friendlyError(e)}';
      });
    }
  }

  /// "Try again" / "Skip this chapter" under a chapter that didn't load.
  void _retryEdge({required bool next, bool skip = false}) {
    setState(() {
      if (next) {
        if (skip) _nextSkip++;
        _nextError = null;
      } else {
        if (skip) _prevSkip++;
        _prevError = null;
      }
    });
    next ? _appendNext() : _prependPrev();
  }

  /// Decodes the pages you'd see first when scrolling into [seg].
  void _precacheSegment(_Segment seg, {required bool fromEnd}) {
    if (!mounted) return;
    final width = _cacheWidth(context);
    for (final i in PagePrefetcher.edgeOrder(seg.pages.length,
        fromEnd: fromEnd, limit: 2)) {
      unawaited(precacheImage(_providerFor(seg.pages[i], width), context,
          onError: (_, _) {}));
    }
  }

  /// Drops chapters far from the one you're in (see [ChapterStrip.trim]).
  void _trimStrip() {
    final dropped = _strip.trim(_index);
    if (dropped.isEmpty) return;
    for (final seg in dropped) {
      _evictDecoded(seg.pages);
    }
    // Something above you was dropped: a previous chapter can load again.
    if (dropped.any((s) => s.index < _index)) _prevSkip = 0;
    setState(() {});
    _retainNearby();
  }

  /// After a load or a jump: if the strip ends (or starts) on screen, load
  /// the next (or previous) chapter without waiting for a scroll.
  void _extendIfNeeded() {
    if (!mounted || !_continuous || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return;
    if (pos.extentAfter < pos.viewportDimension * 2.5) _appendNext();
  }

  /// The strip reached [seg] (it's at the reading line now): it becomes
  /// the chapter you're reading — its bookmark, the bar's page count, the
  /// chapter name on top, and "last read" all follow. Moving down past a
  /// chapter's end counts that chapter as read.
  void _switchTo(_Segment seg, int page, double offset) {
    final old = _active;
    if (old == null || identical(old, seg)) return;
    if (seg.index > old.index) _finishSegment(old);
    _saveTimer?.cancel();
    _evictDecodedAway(seg.index);
    setState(() {
      _active = seg;
      _index = seg.index;
      _pages = seg.pages;
      _keys = seg.keys;
      _fromDownload = seg.fromDownload;
      _finished = seg.finished;
      _page = page;
      _pageOffset = offset;
    });
    _save();
    // History: "last read" moves, as when a chapter is opened.
    unawaited(ref.read(entriesProvider.notifier).startReading(widget.entryId));
    _startPrefetch(seg.pages, page);
    _precacheAround(page);
    _warmNeighbours();
    _trimStrip();
    if (_strip.length >= _restartStripAt) {
      // Nothing above could be dropped: start a fresh strip here.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restartStrip();
      });
    }
  }

  /// Frees decoded images of strip chapters more than one away from [i].
  void _evictDecodedAway(int i) {
    for (final seg in _strip.all) {
      if ((seg.index - i).abs() > 1) _evictDecoded(seg.pages);
    }
  }

  /// Records [seg] as read to the end (once).
  void _finishSegment(_Segment seg) {
    if (seg.finished) return;
    seg.finished = true;
    if (identical(seg, _active)) {
      _markFinished();
    } else {
      _readChapters.finish(widget.entryId, seg.chapter);
    }
  }

  /// Decodes the next few pages (and the one before) so turning or
  /// scrolling to them shows them at once. Errors are ignored here: the
  /// page itself shows "Retry" if it really can't load.
  void _precacheAround(int page) {
    final pages = _pages;
    if (pages == null || !mounted) return;
    final width = _cacheWidth(context);
    for (final i in [for (var d = 1; d <= _decodeAhead; d++) page + d, page - 1]) {
      if (i < 0 || i >= pages.length) continue;
      unawaited(precacheImage(_providerFor(pages[i], width), context,
          onError: (_, _) {}));
    }
  }

  /// A fresh page view controller opening on [page]. The old one is still
  /// attached until the next frame, so it's disposed after that.
  void _newPager(int page) {
    final old = _pager;
    _pager = PageController(initialPage: page);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// Switches layout, staying on the page you're on.
  void _applyMode(ReadingMode mode) {
    if (!mounted || mode == _mode) return;
    final page = _page;
    final toStrip = _mode.paged && !mode.paged;
    if (mode.paged) _newPager(page);
    setState(() {
      _mode = mode;
      _pageOffset = 0;
    });
    final active = _active;
    if (_pages == null || active == null) return;
    if (mode.paged) {
      // One chapter at a time: drop the others the strip had loaded.
      for (final seg in _strip.all) {
        if (!identical(seg, active)) _evictDecoded(seg.pages);
      }
      _strip.reset(active.index, active);
      _resetEdges();
      _warmNeighbours();
    } else if (toStrip) {
      // A new strip that starts with this chapter.
      _strip.reset(active.index, active);
      _resetEdges();
      setState(() => _stripGen++);
      if (page > 0) _jumpTo(page);
      _warmNeighbours();
      WidgetsBinding.instance.addPostFrameCallback((_) => _extendIfNeeded());
    }
    _saveTimer?.cancel();
    _save();
  }

  /// Scrolls to page [p]. Pages far down aren't built yet, so this jumps
  /// close by estimate first and then lands exactly once the page exists.
  /// Page tracking pauses meanwhile, so passing pages (or the end) on the
  /// way doesn't count as reading them.
  void _jumpTo(int p, [int attempt = 0]) {
    if (_mode.paged) {
      // Page changes are tracked (and saved) by _onPageChanged.
      if (_pager?.hasClients ?? false) _pager!.jumpToPage(p);
      return;
    }
    if (attempt == 0) _settling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pages == null || p >= _keys.length) {
        _settling = false;
        return;
      }
      if (attempt > 14) return _endJump(p);
      final ctx = _keys[p].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx);
        // Pages above may still be loading and change size: settle again.
        if (attempt < 10) {
          Future<void>.delayed(const Duration(milliseconds: 450), () {
            if (mounted) _jumpTo(p, attempt + 5);
          });
        } else {
          _scrollIntoPage(p, _pageOffset);
          _endJump(p);
        }
        return;
      }
      if (_scroll.hasClients) {
        final pos = _scroll.position;
        _scroll.jumpTo(
            _estimateOffset(p).clamp(pos.minScrollExtent, pos.maxScrollExtent));
      }
      _jumpTo(p, attempt + 1);
    });
  }

  /// Roughly where page [p] of the chapter you're in starts, in scroll
  /// pixels: measured from one of its pages that's on screen (the strip
  /// can hold several chapters, so the chapter doesn't start at 0), using
  /// the heights of pages already seen and a guess for the rest.
  double _estimateOffset(int p) {
    final width = MediaQuery.sizeOf(context).width;
    final pages = _pages ?? const <_Page>[];
    double height(int i) =>
        width * (i < pages.length ? (_aspects[pages[i].id] ?? 1.4) : 1.4);
    double between(int from, int to) {
      var sum = 0.0;
      final lo = from < to ? from : to, hi = from < to ? to : from;
      for (var i = lo; i < hi; i++) {
        sum += height(i);
      }
      return from < to ? sum : -sum;
    }

    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy - _viewportTop;
      return _scroll.offset + y + between(i, p);
    }
    return _scroll.offset + between(_page, p);
  }

  /// Page [p] is at the top of the screen: scroll [fraction] of its height
  /// further, to the exact spot inside it (long webtoon strips).
  void _scrollIntoPage(int p, double fraction) {
    if (fraction <= 0 || !_scroll.hasClients) return;
    final box = _keys[p].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final target = _scroll.offset + fraction * box.size.height;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  void _endJump(int p) {
    _settling = false;
    if (_page != p) setState(() => _page = p);
    _precacheAround(p);
    _scheduleSave();
  }

  // ---- Progress ----

  void _save({bool finished = false, bool later = false}) {
    final pages = _pages;
    if (pages == null) return;
    final links = _links;
    final entryId = widget.entryId;
    final chapter = _chapter;
    final page = _page;
    final offset = _pageOffset;
    final done = finished || _finished;
    _savedPage = page;
    _savedOffset = offset;
    _savedAt = DateTime.now();
    void run() => links.saveProgress(entryId, chapter,
        page: page, offset: offset, pageCount: pages.length, finished: done);
    if (later) {
      scheduleMicrotask(run);
    } else {
      run();
    }
  }

  /// Debounced save: writes 800 ms after scrolling stops, and at least
  /// every 5 s during a long, continuous scroll.
  void _scheduleSave() {
    _saveTimer?.cancel();
    if (DateTime.now().difference(_savedAt) > const Duration(seconds: 5)) {
      _save();
      return;
    }
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  /// Saves right now (leaving the app).
  void _flush() {
    if (!mounted) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    _save();
  }

  /// Reached the end: remember it, and record the chapter as read (the
  /// library's chapter count moves forward). Reaching the end again, or
  /// tapping "Next" after it, records nothing more ([ReadChaptersNotifier]).
  void _markFinished() {
    if (_finished || _pages == null) return;
    _finished = true;
    _active?.finished = true;
    _save(finished: true);
    _readChapters.finish(widget.entryId, _chapter);
  }

  /// Runs [fn] now, or right after this frame if Flutter is in the middle
  /// of building / laying out (scroll notifications can arrive then, and
  /// state can't change at that point).
  void _safely(VoidCallback fn) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fn();
      });
    } else {
      fn();
    }
  }

  /// Long strip: follows the page at the reading line (40% down the
  /// screen) — across chapter boundaries too — saves the spot, records a
  /// chapter as read when its end comes into view, and loads the next /
  /// previous chapter as you near the end / top of the strip.
  bool _onScroll(ScrollNotification n) {
    final pages = _pages, active = _active;
    if (n.depth != 0 || pages == null || active == null || _mode.paged) {
      return false;
    }
    if (_settling) return false;
    final vp = n.context?.findRenderObject();
    final top =
        vp is RenderBox && vp.attached ? vp.localToGlobal(Offset.zero).dy : 0.0;
    _viewportTop = top;
    final vh = n.metrics.viewportDimension;
    final threshold = top + vh * 0.4;

    // The chapter you're in and its neighbours (the only ones that can be
    // at the reading line after one scroll), top to bottom.
    final segs = _strip.all;
    final at = segs.indexWhere((x) => identical(x, active));
    var seg = active;
    var current = _page;
    var offset = _pageOffset;
    if (at >= 0) {
      outer:
      for (var k = at > 0 ? at - 1 : 0; k <= at + 1 && k < segs.length; k++) {
        final keys = segs[k].keys;
        for (var i = 0; i < keys.length; i++) {
          final box = keys[i].currentContext?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          final y = box.localToGlobal(Offset.zero).dy;
          if (y > threshold) break outer;
          seg = segs[k];
          current = i;
          final h = box.size.height;
          offset = h > 0 ? ((top - y) / h).clamp(0.0, 1.0).toDouble() : 0.0;
        }
      }
    }

    if (!identical(seg, active)) {
      final target = seg, page = current, off = offset;
      _safely(() => _switchTo(target, page, off));
    } else {
      // Only the end of the *last page* finishes a chapter: its end marker
      // has come up into view (not a list that happens to start scrolled
      // down, or pages still loading).
      final end = active.endKey.currentContext?.findRenderObject();
      final atEnd = current >= pages.length - 1 &&
          end is RenderBox &&
          end.attached &&
          end.localToGlobal(Offset.zero).dy < top + vh - 24;
      final moved =
          current != _savedPage || (offset - _savedOffset).abs() > 0.02;
      if (current != _page || moved || (atEnd && !_finished)) {
        _safely(() {
          _pageOffset = offset;
          if (current != _page) {
            setState(() => _page = current);
            _precacheAround(current);
          }
          if (moved) _scheduleSave();
          if (atEnd) _markFinished();
        });
      }
    }

    // Near the bottom / top of the strip: load the next / previous chapter.
    if (_continuous) {
      if (n.metrics.extentAfter < vh * 2.5) _safely(_appendNext);
      if (n.metrics.extentBefore < vh) _safely(_prependPrev);
    }
    return false;
  }

  // ---- Paged modes ----

  void _onPageChanged(int i) {
    final pages = _pages;
    if (pages == null) return;
    final p = i.clamp(0, pages.length - 1);
    if (p != _page || _pageOffset != 0) {
      if (p != _page) _precacheAround(p);
      setState(() {
        _page = p;
        _pageOffset = 0;
      });
      _scheduleSave();
    }
    // The last page (or the end-of-chapter page after it) finishes it.
    if (i >= pages.length - 1) _markFinished();
  }

  /// Turns [dir] pages in reading order (+1 next, -1 back). Past the
  /// end-of-chapter page, opens the next chapter.
  void _step(int dir) {
    final pager = _pager, pages = _pages;
    if (pager == null || !pager.hasClients || pages == null) return;
    final current = pager.page?.round() ?? _page;
    final target = current + dir;
    if (target > pages.length) {
      if (_hasNext) _go(1);
      return;
    }
    if (target < 0) return;
    unawaited(pager.animateToPage(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut));
  }

  /// +1 or -1 for a tap or arrow on the right ([right]) or left side: the
  /// next page is on the right for left-to-right, on the left for manga.
  int _sideDir({required bool right}) =>
      right == (_mode == ReadingMode.pagedLtr) ? 1 : -1;

  void _onTap(TapUpDetails d) {
    if (!_mode.paged || _pages == null) return _toggleUi();
    final w = MediaQuery.sizeOf(context).width;
    final x = d.localPosition.dx;
    if (x < w * 0.3) {
      _step(_sideDir(right: false));
    } else if (x > w * 0.7) {
      _step(_sideDir(right: true));
    } else {
      _toggleUi();
    }
  }

  /// Keyboards (and D-pads): left / right turn pages in paged modes, up /
  /// down / page keys / space scroll the long strip.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if ((e is! KeyDownEvent && e is! KeyRepeatEvent) || _pages == null) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (_mode.paged) {
      if (k == LogicalKeyboardKey.arrowRight) {
        _step(_sideDir(right: true));
      } else if (k == LogicalKeyboardKey.arrowLeft) {
        _step(_sideDir(right: false));
      } else if (k == LogicalKeyboardKey.pageDown ||
          k == LogicalKeyboardKey.space) {
        _step(1);
      } else if (k == LogicalKeyboardKey.pageUp) {
        _step(-1);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (!_scroll.hasClients) return KeyEventResult.ignored;
    final double dir;
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.space) {
      dir = 1;
    } else if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.pageUp) {
      dir = -1;
    } else {
      return KeyEventResult.ignored;
    }
    final pos = _scroll.position;
    final step = pos.viewportDimension *
        (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp
            ? 0.3
            : 0.85);
    unawaited(_scroll.animateTo(
        (pos.pixels + dir * step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut));
    return KeyEventResult.handled;
  }

  // ---- Reader settings ----

  String? get _typeLabel => (ref.read(entriesProvider).value ?? const <Entry>[])
      .where((e) => e.id == widget.entryId)
      .firstOrNull
      ?.type
      .label;

  Future<void> _openSettings() async {
    final type = _typeLabel;
    final fallback = defaultReadingMode(type);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => Consumer(builder: (sheet, ref, _) {
        final picked = ref.watch(
            readingModesProvider.select((m) => m[widget.entryId]));
        final current = picked ?? fallback;
        final modes = ref.read(readingModesProvider.notifier);
        void choose(ReadingMode? m) {
          modes.set(widget.entryId, m);
          Navigator.of(sheet).pop();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Reading mode', style: sheet.text.titleMedium),
              ),
              for (final m in ReadingMode.values)
                ListTile(
                  leading: Icon(_modeIcon(m)),
                  title: Text(m.label),
                  subtitle: m == fallback
                      ? Text('Default for ${type ?? 'this title'}')
                      : null,
                  selected: m == current,
                  trailing: m == current
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => choose(m),
                ),
              if (picked != null)
                ListTile(
                  leading: const Icon(Icons.restart_alt_rounded),
                  title: const Text('Use default'),
                  subtitle: Text('${fallback.label} for ${type ?? 'this type'}'),
                  onTap: () => choose(null),
                ),
              if (!current.paged) ...[
                const Divider(indent: 16, endIndent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.low_priority_rounded),
                  title: const Text('Continuous scrolling'),
                  subtitle: const Text(
                      'Scroll straight into the next or previous chapter'),
                  value: ref.watch(continuousScrollProvider),
                  onChanged: (v) =>
                      ref.read(continuousScrollProvider.notifier).set(v),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      }),
    );
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.order.length) return;
    if (delta > 0) _markFinished();
    _saveTimer?.cancel();
    _save();
    setState(() {
      _index = next;
      _startPage = 0;
      _startOffset = 0;
    });
    _load();
  }

  void _toggleUi() {
    setState(() => _ui = !_ui);
    unawaited(SystemChrome.setEnabledSystemUIMode(
        _ui ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky));
  }

  void _downloadThis() {
    final entry = (ref.read(entriesProvider).value ?? const <Entry>[])
        .where((e) => e.id == widget.entryId)
        .firstOrNull;
    final link = ref.read(readingLinksProvider)[widget.entryId];
    if (entry == null || link == null) return;
    try {
      final n =
          ref.read(downloadsProvider.notifier).enqueue(entry, link, [_chapter]);
      showSnack(context, n == 0 ? 'Already downloading' : 'Downloading this chapter');
    } catch (e) {
      showSnack(context, friendlyError(e), error: true);
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final downloaded = ref.watch(downloadsProvider
        .select((s) => s.find(widget.entryId, _chapter.key) != null));
    final queued = ref.watch(downloadsProvider
        .select((s) => s.isQueued(widget.entryId, _chapter.key)));

    final Widget content;
    if (_error != null) {
      content = _ErrorView(
        message: _error!,
        offline: _offline,
        onRetry: _load,
        onBack: () => Navigator.of(context).pop(),
      );
    } else if (pages == null) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_mode.paged) {
      final size = MediaQuery.sizeOf(context);
      final cacheWidth = _cacheWidth(context);
      content = PageView.builder(
        // A fresh view per chapter / mode (its controller knows the page).
        key: ObjectKey(_pager),
        controller: _pager,
        // Keeps the page on each side built, so a turn shows it at once.
        allowImplicitScrolling: true,
        // Manga: the next page comes in from the left.
        reverse: _mode == ReadingMode.pagedRtl,
        itemCount: pages.length + 1,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, i) {
          if (i == pages.length) {
            return Center(
                child: SingleChildScrollView(child: _footer(context)));
          }
          final page = pages[i];
          return Center(
            child: _PageImage(
              key: ValueKey(page.file ?? page.url),
              image: (attempt) =>
                  _providerFor(page, cacheWidth, attempt: attempt),
              width: size.width,
              height: size.height,
              fit: BoxFit.contain,
            ),
          );
        },
      );
    } else {
      content = _buildStrip(context);
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTap,
                child: content,
              ),
            ),
            // ---- Top bar ----
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              top: _ui ? 0 : -140,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black.withValues(alpha: 0.82),
                child: SafeArea(
                  bottom: false,
                  child: Row(children: [
                    const BackButton(color: Colors.white),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_chapter.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.titleSmall
                                  ?.copyWith(color: Colors.white)),
                          Text(
                            [
                              _chapter.scanlatorLabel,
                              if (_fromDownload) 'downloaded',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelSmall
                                ?.copyWith(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    Consumer(builder: (context, ref, _) {
                      final key = _chapter.key;
                      final fav = ref.watch(favoriteChaptersProvider.select(
                          (m) => m[widget.entryId]?.contains(key) ?? false));
                      return IconButton(
                        tooltip:
                            fav ? 'Remove from favorites' : 'Add to favorites',
                        onPressed: () {
                          final on = ref
                              .read(favoriteChaptersProvider.notifier)
                              .toggle(widget.entryId, key);
                          ScaffoldMessenger.maybeOf(context)
                            ?..hideCurrentSnackBar()
                            ..showSnackBar(SnackBar(
                              duration: const Duration(seconds: 2),
                              content: Text(on
                                  ? 'Added to favorite chapters'
                                  : 'Removed from favorite chapters'),
                            ));
                        },
                        icon: Icon(
                          fav ? Icons.star_rounded : Icons.star_outline_rounded,
                          color: fav ? const Color(0xFFFFC94D) : Colors.white,
                        ),
                      );
                    }),
                    if (DownloadStore.supported)
                      IconButton(
                        tooltip: downloaded
                            ? 'Downloaded'
                            : queued
                                ? 'Downloading…'
                                : 'Download chapter',
                        onPressed: downloaded || queued ? null : _downloadThis,
                        icon: Icon(
                          downloaded
                              ? Icons.download_done_rounded
                              : queued
                                  ? Icons.downloading_rounded
                                  : Icons.download_outlined,
                          color: Colors.white,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Reader settings',
                      onPressed: _openSettings,
                      icon: Icon(_modeIcon(_mode), color: Colors.white),
                    ),
                  ]),
                ),
              ),
            ),
            // ---- Bottom bar ----
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              bottom: _ui ? 0 : -160,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black.withValues(alpha: 0.82),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                    child: Row(children: [
                      IconButton(
                        tooltip: 'Previous chapter',
                        onPressed: _hasPrev ? () => _go(-1) : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                        color: Colors.white,
                        disabledColor: Colors.white24,
                      ),
                      Expanded(
                        child: pages == null || pages.length < 2
                            ? const SizedBox(height: 48)
                            // Manga: the slider runs right to left too.
                            : Directionality(
                                textDirection: _mode == ReadingMode.pagedRtl
                                    ? TextDirection.rtl
                                    : TextDirection.ltr,
                                child: Row(children: [
                                Text('${_page + 1}',
                                    style: const TextStyle(color: Colors.white)),
                                Expanded(
                                  child: Slider(
                                    value: _page.toDouble(),
                                    max: (pages.length - 1).toDouble(),
                                    divisions: pages.length - 1,
                                    onChanged: (v) =>
                                        setState(() => _page = v.round()),
                                    onChangeEnd: (v) {
                                      _pageOffset = 0;
                                      // Load from here on first.
                                      _prefetch?.focus(v.round());
                                      _jumpTo(v.round());
                                    },
                                  ),
                                ),
                                Text('${pages.length}',
                                    style: const TextStyle(color: Colors.white)),
                              ])),
                      ),
                      IconButton(
                        tooltip: 'Next chapter',
                        onPressed: _hasNext ? () => _go(1) : null,
                        icon: const Icon(Icons.skip_next_rounded),
                        color: Colors.white,
                        disabledColor: Colors.white24,
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Long strip ----

  /// The rows of the strip, top to bottom: the head (above the first
  /// chapter), each chapter's pages, a break between chapters, and the
  /// tail after the last one.
  List<_Row> _stripRows() {
    final segs = _strip.all;
    return [
      const _Row(_RowKind.head),
      for (var k = 0; k < segs.length; k++) ...[
        for (var i = 0; i < segs[k].pages.length; i++)
          _Row(_RowKind.page, segs[k], i),
        if (k + 1 < segs.length)
          _Row(_RowKind.divider, segs[k], 0, segs[k + 1])
        else
          _Row(_RowKind.tail, segs[k]),
      ],
    ];
  }

  /// The long strip: one scroll view through every loaded chapter. Rows
  /// above the anchor chapter are in a list that grows upwards from it
  /// (the scroll view's center), so a previous chapter loading above you
  /// leaves the screen exactly where it was; later chapters grow
  /// downwards. Only rows near the screen are built.
  Widget _buildStrip(BuildContext context) {
    final rows = _stripRows();
    // Where the anchor chapter starts: everything above it grows upwards.
    var split = rows.indexWhere((r) =>
        r.kind == _RowKind.page && r.seg!.index >= _strip.anchor);
    if (split < 0) split = rows.length;
    final up = rows.sublist(0, split).reversed.toList();
    final down = rows.sublist(split);
    final size = MediaQuery.sizeOf(context);
    final cacheWidth = _cacheWidth(context);
    Widget row(_Row r) => _stripRow(context, r, size, cacheWidth);

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
        // A fresh scroll position for each new strip.
        key: ValueKey('strip:$_stripGen'),
        controller: _scroll,
        center: _centerKey,
        // Builds about one screen ahead and behind, no more: pages further
        // away are disposed (their decoded images can leave memory), and
        // the next pages are already decoded by _precacheAround.
        scrollCacheExtent: const ScrollCacheExtent.viewport(1.0),
        slivers: [
          SliverList.builder(
            itemCount: up.length,
            addAutomaticKeepAlives: false,
            itemBuilder: (_, i) => row(up[i]),
          ),
          SliverList.builder(
            key: _centerKey,
            itemCount: down.length,
            addAutomaticKeepAlives: false,
            itemBuilder: (_, i) => row(down[i]),
          ),
        ],
      ),
    );
  }

  Widget _stripRow(BuildContext context, _Row r, Size size, int cacheWidth) {
    switch (r.kind) {
      case _RowKind.page:
        final seg = r.seg!;
        final page = seg.pages[r.page];
        final id = page.id;
        return KeyedSubtree(
          key: seg.keys[r.page],
          child: _PageImage(
            key: ValueKey(id),
            image: (attempt) => _providerFor(page, cacheWidth, attempt: attempt),
            width: size.width,
            aspect: _aspects[id],
            onAspect: (a) => _aspects[id] = a,
          ),
        );
      case _RowKind.divider:
        return KeyedSubtree(
          key: r.seg!.endKey,
          child: _ChapterBreak(ended: r.seg!.chapter, next: r.next!.chapter),
        );
      case _RowKind.tail:
        return KeyedSubtree(key: r.seg!.endKey, child: _stripTail(context));
      case _RowKind.head:
        return _stripHead(context);
    }
  }

  /// Above the first loaded chapter: the previous one loading (or why it
  /// didn't), or the start of the series.
  Widget _stripHead(BuildContext context) {
    final first = _strip.firstIndex ?? _index;
    final prev = first - 1 - _prevSkip;
    if (!_continuous || prev < 0) {
      return _EdgeNote(
        icon: Icons.first_page_rounded,
        text: prev < 0 && _continuous
            ? 'This is the first chapter'
            : 'Start of ${widget.order[first].name}',
      );
    }
    if (_prevError != null) {
      return _EdgeError(
        message: _prevError!,
        onRetry: () => _retryEdge(next: false),
        onSkip: prev > 0 ? () => _retryEdge(next: false, skip: true) : null,
      );
    }
    return _EdgeNote(
      icon: Icons.expand_less_rounded,
      text: _loadingPrev
          ? 'Loading ${widget.order[prev].name}…'
          : 'Scroll up for ${widget.order[prev].name}',
      loading: _loadingPrev,
      onTap: _loadingPrev ? null : _prependPrev,
    );
  }

  /// After the last loaded chapter: the next one loading (or why it
  /// didn't), or the end of what's out.
  Widget _stripTail(BuildContext context) {
    final last = _strip.lastIndex ?? _index;
    final next = last + 1 + _nextSkip;
    if (!_continuous) return _footer(context);
    final ended = widget.order[last];
    if (next >= widget.order.length) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 160),
        child: Column(children: [
          Text('End of ${ended.name}',
              textAlign: TextAlign.center,
              style: context.text.titleMedium?.copyWith(color: Colors.white)),
          const SizedBox(height: 8),
          Text("You're caught up — that's the latest chapter.",
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back to chapters'),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 160),
      child: Column(children: [
        _ChapterBreak(ended: ended, next: widget.order[next]),
        if (_nextError != null)
          _EdgeError(
            message: _nextError!,
            onRetry: () => _retryEdge(next: true),
            onSkip: next + 1 < widget.order.length
                ? () => _retryEdge(next: true, skip: true)
                : null,
          )
        else
          _EdgeNote(
            icon: Icons.expand_more_rounded,
            text: 'Loading ${widget.order[next].name}…',
            loading: true,
          ),
      ]),
    );
  }

  Widget _footer(BuildContext context) {
    final next = _hasNext ? widget.order[_index + 1] : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 160),
      child: Column(children: [
        Text('End of ${_chapter.name}',
            textAlign: TextAlign.center,
            style: context.text.titleMedium?.copyWith(color: Colors.white)),
        const SizedBox(height: 16),
        if (next != null)
          FilledButton.icon(
            onPressed: () => _go(1),
            icon: const Icon(Icons.skip_next_rounded),
            label: Text('Next: ${next.name}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        else
          Text("You're caught up.",
              style: context.text.bodyMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to chapters'),
        ),
      ]),
    );
  }
}

IconData _modeIcon(ReadingMode m) => switch (m) {
      ReadingMode.pagedRtl => Icons.format_textdirection_r_to_l_rounded,
      ReadingMode.pagedLtr => Icons.format_textdirection_l_to_r_rounded,
      ReadingMode.longStrip => Icons.view_day_outlined,
    };

class _PageImage extends StatefulWidget {
  const _PageImage({
    super.key,
    required this.image,
    required this.width,
    this.height,
    this.fit = BoxFit.fitWidth,
    this.aspect,
    this.onAspect,
  });

  /// Long strip: the page's height / width when known (seen before), so
  /// it keeps its real height while it loads.
  final double? aspect;

  /// Called with the page's height / width once its image is known.
  final void Function(double aspect)? onAspect;

  /// The page's image for a given load [attempt] ("Retry" loads it again).
  final ImageProvider Function(int attempt) image;
  final double width;

  /// Paged modes: the whole page fits in [width] x [height]. Null in the
  /// long strip, where pages are as tall as their width makes them.
  final double? height;
  final BoxFit fit;

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> with SingleTickerProviderStateMixin {
  int _attempt = 0;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  late final TransformationController _transformationController = TransformationController();
  AnimationController? _animController;
  Animation<Matrix4>? _animation;

  void _handleDoubleTap() {
    _animController?.dispose();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    final Matrix4 begin = _transformationController.value;
    final Matrix4 target = begin.isIdentity()
        ? Matrix4.diagonal3Values(2.5, 2.5, 1.0)
        : Matrix4.identity();
    _animation = Matrix4Tween(begin: begin, end: target).animate(
      CurvedAnimation(parent: _animController!, curve: Curves.easeOutCubic),
    );
    _animController!.addListener(() {
      _transformationController.value = _animation!.value;
    });
    _animController!.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(_PageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen();
  }

  @override
  void dispose() {
    _animController?.dispose();
    _transformationController.dispose();
    _unlisten();
    super.dispose();
  }

  /// Learns the page's size from its image (the same one [Image] shows,
  /// so nothing extra is loaded).
  void _listen() {
    final cb = widget.onAspect;
    if (cb == null) return _unlisten();
    final stream =
        widget.image(_attempt).resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) return;
    _unlisten();
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width;
      if (w > 0) cb(info.image.height / w);
      info.dispose();
    }, onError: (_, _) {});
    _stream = stream..addListener(listener);
    _listener = listener;
  }

  void _unlisten() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = SizedBox(
      width: widget.width,
      height: widget.height ?? widget.width * (widget.aspect ?? 1.4),
      child: const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white54),
        ),
      ),
    );
    Widget frame(BuildContext context, Widget child, int? frame, bool sync) =>
        (frame == null && !sync) ? placeholder : child;
    Widget error(BuildContext context, Object e, StackTrace? s) => SizedBox(
          width: widget.width,
          height: widget.height ?? widget.width * 0.9,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.broken_image_outlined, color: Colors.white54),
              const SizedBox(height: 8),
              const Text("Couldn't load this page",
                  style: TextStyle(color: Colors.white70)),
              TextButton(
                onPressed: () {
                  setState(() => _attempt++);
                  _listen();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        );

    final imageWidget = Image(
      image: widget.image(_attempt),
      key: ValueKey(_attempt),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: frame,
      errorBuilder: error,
    );

    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 1.0,
      maxScale: 5.0,
      constrained: true,
      child: GestureDetector(
        onDoubleTap: _handleDoubleTap,
        child: imageWidget,
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.offline,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final bool offline;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
              color: Colors.white70, size: 40),
          const SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style: context.text.bodyLarge?.copyWith(color: Colors.white)),
          if (offline) ...[
            const SizedBox(height: 6),
            Text('Download chapters while online to read them anywhere.',
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(color: Colors.white70)),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
          TextButton(onPressed: onBack, child: const Text('Back')),
        ]),
      ),
    );
  }
}

/// Between two chapters in the long strip: where one ends and the next
/// begins, so crossing over is clear without stopping you.
class _ChapterBreak extends StatelessWidget {
  const _ChapterBreak({required this.ended, required this.next});
  final ChapterInfo ended;
  final ChapterInfo next;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.labelMedium?.copyWith(color: Colors.white60);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(children: [
        Text('End of ${ended.name}',
            textAlign: TextAlign.center, style: muted),
        const SizedBox(height: 10),
        Row(children: [
          const Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.keyboard_double_arrow_down_rounded,
                size: 18, color: Colors.white.withValues(alpha: 0.6)),
          ),
          const Expanded(child: Divider(color: Colors.white24)),
        ]),
        const SizedBox(height: 10),
        Text(next.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.titleSmall?.copyWith(color: Colors.white)),
      ]),
    );
  }
}

/// A quiet line at the top or bottom of the strip.
class _EdgeNote extends StatelessWidget {
  const _EdgeNote({
    required this.icon,
    required this.text,
    this.loading = false,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white54),
            )
          else
            Icon(icon, size: 20, color: Colors.white54),
          const SizedBox(width: 10),
          Flexible(
            child: Text(text,
                textAlign: TextAlign.center,
                style: context.text.labelLarge?.copyWith(color: Colors.white70)),
          ),
        ]),
      ),
    );
  }
}

/// A neighbouring chapter that didn't load, in the strip: why, "Try
/// again", and "Skip this chapter" when there's another one beyond it.
class _EdgeError extends StatelessWidget {
  const _EdgeError({required this.message, required this.onRetry, this.onSkip});
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Column(children: [
        const Icon(Icons.error_outline_rounded, color: Colors.white70),
        const SizedBox(height: 8),
        Text(message,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(color: Colors.white)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
          if (onSkip != null)
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              onPressed: onSkip,
              child: const Text('Skip this chapter'),
            ),
        ]),
      ]),
    );
  }
}
