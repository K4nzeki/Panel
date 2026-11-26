import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/downloads.dart';
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
}

/// Reads a chapter top to bottom (works for manga pages and webtoon
/// strips). Downloaded chapters open from the phone with no connection.
/// Remembers the page you're on, marks the chapter read when you reach the
/// end, and moves on through [order] (oldest first, scanlator filter
/// applied). Tap to show or hide the controls.
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
  late int _index = widget.index.clamp(0, widget.order.length - 1);
  late int _startPage = widget.startPage;
  late double _startOffset = widget.startOffset;
  late final ReadingLinksNotifier _links;
  AppLifecycleListener? _lifecycle;

  // keepScrollOffset: false — otherwise the next chapter's list reopens at
  // the previous chapter's scroll offset (PageStorage), often right at the
  // end, and the first scroll marked a chapter you never read as finished.
  final _scroll = ScrollController(keepScrollOffset: false);
  List<_Page>? _pages;
  List<GlobalKey> _keys = const [];
  Map<String, String> _headers = const {};

  /// Set for extension sources: they load their own images.
  ImageFetcher? _fetcher;
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

  @override
  void initState() {
    super.initState();
    // Kept for dispose(), where ref can't be used any more.
    _links = ref.read(readingLinksProvider.notifier);
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
    _scroll.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  // ---- Loading ----

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _pages = null;
      _error = null;
      _finished = false;
      _settling = false;
      _page = 0;
      _pageOffset = 0;
    });
    final ch = _chapter;
    final List<_Page> pages;
    try {
      final dl = ref.read(downloadsProvider).find(widget.entryId, ch.key);
      if (dl != null && dl.files.isNotEmpty) {
        pages = [for (final p in dl.paths) _Page.file(p)];
        _fromDownload = true;
      } else {
        final link = ref.read(readingLinksProvider)[widget.entryId];
        if (link == null) {
          throw const SourceException('Choose a source for this title first.');
        }
        final source = ref.read(readerSourcesProvider).forLink(link);
        _headers = source.imageHeaders;
        _fetcher = source is ImageFetcher ? source as ImageFetcher : null;
        pages = [for (final u in await source.pages(ch)) _Page.net(u)];
        _fromDownload = false;
      }
      if (pages.isEmpty) throw const SourceException('This chapter has no pages.');
    } catch (e) {
      if (!mounted || gen != _gen) return;
      final err = sourceError(e, 'The source');
      setState(() {
        _offline = err.offline;
        _error = err.offline
            ? "This chapter isn't downloaded and you're offline."
            : err.message;
      });
      return;
    }
    if (!mounted || gen != _gen) return;
    final start = _startPage.clamp(0, pages.length - 1);
    // A saved offset only applies to the page it was saved on.
    final offset = start == _startPage ? _startOffset.clamp(0.0, 1.0) : 0.0;
    setState(() {
      _pages = pages;
      _keys = List.generate(pages.length, (_) => GlobalKey());
      _page = start;
      _pageOffset = offset.toDouble();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _save();
    ref.read(entriesProvider.notifier).touch(widget.entryId);
    if (start > 0 || offset > 0) _jumpTo(start);
  }

  /// Scrolls to page [p]. Pages far down aren't built yet, so this jumps
  /// close by estimate first and then lands exactly once the page exists.
  /// Page tracking pauses meanwhile, so passing pages (or the end) on the
  /// way doesn't count as reading them.
  void _jumpTo(int p, [int attempt = 0]) {
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
        final est = p * MediaQuery.sizeOf(context).width * 1.4;
        _scroll.jumpTo(est.clamp(0.0, _scroll.position.maxScrollExtent));
      }
      _jumpTo(p, attempt + 1);
    });
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

  /// Reached the end: remember it, and move the library forward.
  void _markFinished() {
    if (_finished || _pages == null) return;
    _finished = true;
    _save(finished: true);
    final n = _chapter.number;
    if (n != null) {
      unawaited(ref
          .read(entriesProvider.notifier)
          .markReadUpTo(widget.entryId, n.floor()));
    }
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

  bool _onScroll(ScrollNotification n) {
    final pages = _pages;
    if (n.depth != 0 || pages == null || _settling) return false;
    final vp = n.context?.findRenderObject();
    final top =
        vp is RenderBox && vp.attached ? vp.localToGlobal(Offset.zero).dy : 0.0;
    final threshold = top + MediaQuery.sizeOf(context).height * 0.4;
    var current = _page;
    var offset = _pageOffset;
    for (var i = 0; i < _keys.length; i++) {
      final ctx = _keys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y <= threshold) {
        current = i;
        final h = box.size.height;
        offset = h > 0 ? ((top - y) / h).clamp(0.0, 1.0).toDouble() : 0.0;
      } else {
        break;
      }
    }
    // Only the end of the *last page* finishes a chapter (not a list that
    // happens to start scrolled down, or pages still loading).
    final atEnd = n.metrics.extentAfter < 48 && current >= pages.length - 1;
    final moved =
        current != _savedPage || (offset - _savedOffset).abs() > 0.02;
    if (current != _page || moved || (atEnd && !_finished)) {
      _safely(() {
        _pageOffset = offset;
        if (current != _page) setState(() => _page = current);
        if (moved) _scheduleSave();
        if (atEnd) _markFinished();
      });
    }
    return false;
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
    } else {
      final width = MediaQuery.sizeOf(context).width;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      content = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.builder(
          // A fresh list (and scroll position) per chapter.
          key: ValueKey('chapter:${_chapter.key}'),
          controller: _scroll,
          padding: EdgeInsets.zero,
          itemCount: pages.length + 1,
          itemBuilder: (context, i) {
            if (i == pages.length) return _footer(context);
            return KeyedSubtree(
              key: _keys[i],
              child: _PageImage(
                page: pages[i],
                headers: _headers,
                fetcher: _fetcher,
                width: width,
                cacheWidth: (width * dpr).round(),
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleUi,
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
                          : Row(children: [
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
                                    _jumpTo(v.round());
                                  },
                                ),
                              ),
                              Text('${pages.length}',
                                  style: const TextStyle(color: Colors.white)),
                            ]),
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

class _PageImage extends StatefulWidget {
  const _PageImage({
    required this.page,
    required this.headers,
    required this.width,
    required this.cacheWidth,
    this.fetcher,
  });

  final _Page page;
  final Map<String, String> headers;
  final ImageFetcher? fetcher;
  final double width;
  final int cacheWidth;

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) {
    final placeholder = SizedBox(
      width: widget.width,
      height: widget.width * 1.4,
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
          height: widget.width * 0.9,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.broken_image_outlined, color: Colors.white54),
              const SizedBox(height: 8),
              const Text("Couldn't load this page",
                  style: TextStyle(color: Colors.white70)),
              TextButton(
                onPressed: () => setState(() => _attempt++),
                child: const Text('Retry'),
              ),
            ],
          ),
        );

    final p = widget.page;
    if (p.file != null) {
      return Image.file(
        File(p.file!),
        key: ValueKey('${p.file}#$_attempt'),
        width: widget.width,
        fit: BoxFit.fitWidth,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
        frameBuilder: frame,
        errorBuilder: error,
      );
    }
    if (widget.fetcher case final fetcher?) {
      return Image(
        image: ResizeImage.resizeIfNeeded(widget.cacheWidth, null,
            FetchedImageProvider(p.url!, fetcher, attempt: _attempt)),
        key: ValueKey('${p.url}#$_attempt'),
        width: widget.width,
        fit: BoxFit.fitWidth,
        gaplessPlayback: true,
        frameBuilder: frame,
        errorBuilder: error,
      );
    }
    return Image.network(
      p.url!,
      key: ValueKey('${p.url}#$_attempt'),
      headers: widget.headers,
      width: widget.width,
      fit: BoxFit.fitWidth,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      frameBuilder: frame,
      errorBuilder: error,
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
