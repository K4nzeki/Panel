import 'dart:async';

/// Loads every page of a chapter in the background, a few at a time, so
/// pages are ready before you reach them.
///
/// Order: the page you opened on, then every page after it, then the pages
/// before it (you're more likely to read on than go back). [focus] moves a
/// page (and the ones after it) to the front, e.g. after jumping with the
/// slider. [cancel] stops it: nothing new starts, and loads still running
/// finish quietly without being recorded.
///
/// One failing page never stops the rest; it's listed in [failed] and the
/// reader loads it again when it's shown.
class PagePrefetcher {
  PagePrefetcher({
    required this.count,
    required Future<void> Function(int index) load,
    int start = 0,
    this.concurrency = 3,
  })  : assert(concurrency > 0),
        _load = load,
        _queue = prefetchOrder(count, start);

  final int count;
  final int concurrency;
  final Future<void> Function(int index) _load;

  final List<int> _queue;
  final _running = <int>{};

  /// Pages loaded.
  final done = <int>{};

  /// Pages that failed to load (each is tried once).
  final failed = <int>{};

  bool _started = false;
  bool _cancelled = false;
  int _workers = 0;
  final _finished = Completer<void>();

  bool get cancelled => _cancelled;

  /// Every page was tried (or it was cancelled).
  bool get isFinished => _finished.isCompleted;

  /// Completes when every page was tried, or soon after [cancel].
  Future<void> get whenFinished => _finished.future;

  /// The order pages are loaded in when the chapter opens on [start].
  static List<int> prefetchOrder(int count, int start) {
    if (count <= 0) return [];
    final s = start.clamp(0, count - 1);
    return [
      for (var i = s; i < count; i++) i,
      for (var i = s - 1; i >= 0; i--) i,
    ];
  }

  void start() {
    if (_started || _cancelled) return;
    _started = true;
    if (_queue.isEmpty) {
      _finish();
      return;
    }
    final n = concurrency < _queue.length ? concurrency : _queue.length;
    for (var i = 0; i < n; i++) {
      _workers++;
      unawaited(_work());
    }
  }

  /// Loads [index] and the pages after it next.
  void focus(int index) {
    if (_cancelled || index < 0 || index >= count) return;
    final ahead = [
      for (var i = index; i < count; i++)
        if (_queue.contains(i)) i,
    ];
    if (ahead.isEmpty) return;
    _queue.removeWhere(ahead.contains);
    _queue.insertAll(0, ahead);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _queue.clear();
    if (_workers == 0) _finish();
  }

  Future<void> _work() async {
    try {
      while (!_cancelled && _queue.isNotEmpty) {
        final i = _queue.removeAt(0);
        if (done.contains(i) || _running.contains(i)) continue;
        _running.add(i);
        try {
          await _load(i);
          if (!_cancelled) done.add(i);
        } catch (_) {
          if (!_cancelled) failed.add(i);
        } finally {
          _running.remove(i);
        }
      }
    } finally {
      _workers--;
      if (_workers == 0) _finish();
    }
  }

  void _finish() {
    if (!_finished.isCompleted) _finished.complete();
  }
}
