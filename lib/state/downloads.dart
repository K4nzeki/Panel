import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/entry.dart';
import '../models/reader.dart';
import '../services/background.dart';
import '../services/downloads.dart';
import '../services/sources/reader_source.dart';
import 'providers.dart';
import 'reader.dart';

/// A chapter waiting to be downloaded.
class DownloadTask {
  const DownloadTask({
    required this.entryId,
    required this.entryTitle,
    required this.link,
    required this.chapter,
  });

  final String entryId;
  final String entryTitle;
  final ReadingLink link;
  final ChapterInfo chapter;

  String get id => downloadId(entryId, chapter.key);

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'entry_title': entryTitle,
        'link': link.toJson(),
        'chapter': chapter.toJson(),
      };

  static DownloadTask? fromJson(Object? j) {
    if (j is! Map) return null;
    final link = ReadingLink.fromJson(j['link']);
    final ch = ChapterInfo.fromJson(j['chapter']);
    final id = j['entry_id'];
    if (link == null || ch == null || id is! String) return null;
    return DownloadTask(
        entryId: id,
        entryTitle: '${j['entry_title'] ?? ''}',
        link: link,
        chapter: ch);
  }
}

class DownloadsState {
  const DownloadsState({
    this.done = const {},
    this.queue = const [],
    this.activeId,
    this.activeDone = 0,
    this.activeTotal = 0,
    this.waitingForConnection = false,
    this.failed = const {},
    this.scanned = false,
  });

  /// Finished downloads by [downloadId].
  final Map<String, DownloadedChapter> done;

  /// Waiting, in order (the active one first).
  final List<DownloadTask> queue;
  final String? activeId;
  final int activeDone;
  final int activeTotal;

  /// Offline: the queue continues when the connection is back.
  final bool waitingForConnection;

  /// Chapters whose last try failed, with the reason.
  final Map<String, String> failed;

  /// The downloads folder has been read.
  final bool scanned;

  DownloadedChapter? find(String entryId, String chapterKey) =>
      done[downloadId(entryId, chapterKey)];

  bool isQueued(String entryId, String chapterKey) {
    final id = downloadId(entryId, chapterKey);
    return queue.any((t) => t.id == id);
  }

  /// New list each call (callers may sort it).
  List<DownloadedChapter> forEntry(String entryId) =>
      [for (final d in done.values) if (d.entryId == entryId) d];

  DownloadsState copyWith({
    Map<String, DownloadedChapter>? done,
    List<DownloadTask>? queue,
    String? activeId,
    bool clearActive = false,
    int? activeDone,
    int? activeTotal,
    bool? waitingForConnection,
    Map<String, String>? failed,
    bool? scanned,
  }) =>
      DownloadsState(
        done: done ?? this.done,
        queue: queue ?? this.queue,
        activeId: clearActive ? null : (activeId ?? this.activeId),
        activeDone: activeDone ?? this.activeDone,
        activeTotal: activeTotal ?? this.activeTotal,
        waitingForConnection: waitingForConnection ?? this.waitingForConnection,
        failed: failed ?? this.failed,
        scanned: scanned ?? this.scanned,
      );
}

/// Downloads chapters one at a time into Panel's folder on the phone (see
/// [DownloadStore]). The queue is saved, so it carries on after the app
/// restarts or the connection comes back.
class DownloadsNotifier extends Notifier<DownloadsState> {
  static const _queueKey = 'download_queue_v1';

  final _client = http.Client();
  bool _running = false;
  String? _cancel;
  AppLifecycleListener? _lifecycle;

  @override
  DownloadsState build() {
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () {
      if (state.waitingForConnection) resume();
    });
    ref.onDispose(() => _lifecycle?.dispose());
    final saved = _readQueue();
    unawaited(Future<void>.delayed(Duration.zero, _scan));
    return DownloadsState(queue: saved);
  }

  Future<void> _scan() async {
    final found = await DownloadStore.scan();
    state = state.copyWith(
      done: {for (final d in found) if (d.complete) d.id: d},
      scanned: true,
    );
    if (state.queue.isNotEmpty) unawaited(_run());
  }

  List<DownloadTask> _readQueue() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(_queueKey);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is! List) return const [];
      return [
        for (final t in j)
          if (DownloadTask.fromJson(t) case final task?) task,
      ];
    } catch (_) {
      return const [];
    }
  }

  void _saveQueue() => unawaited(ref.read(sharedPrefsProvider).setString(
      _queueKey, jsonEncode([for (final t in state.queue) t.toJson()])));

  /// Queues [chapters] of [entry] (skips ones already downloaded or queued).
  /// Returns how many were added.
  int enqueue(Entry entry, ReadingLink link, Iterable<ChapterInfo> chapters) {
    if (!DownloadStore.supported) {
      throw const SourceException("Downloads aren't available on this device.");
    }
    final add = <DownloadTask>[
      for (final c in chapters)
        if (state.find(entry.id, c.key) == null &&
            !state.isQueued(entry.id, c.key))
          DownloadTask(
              entryId: entry.id, entryTitle: entry.title, link: link, chapter: c),
    ];
    if (add.isEmpty) return 0;
    final failed = {...state.failed}
      ..removeWhere((k, _) => add.any((t) => t.id == k));
    state = state.copyWith(queue: [...state.queue, ...add], failed: failed);
    _saveQueue();
    unawaited(_run());
    return add.length;
  }

  /// Tries the queue again (after being offline).
  void resume() {
    state = state.copyWith(waitingForConnection: false);
    unawaited(_run());
  }

  void cancel(String entryId, String chapterKey) {
    final id = downloadId(entryId, chapterKey);
    if (state.activeId == id) _cancel = id;
    state = state.copyWith(
        queue: [for (final t in state.queue) if (t.id != id) t]);
    _saveQueue();
  }

  void cancelAll() {
    _cancel = state.activeId;
    state = state.copyWith(queue: const []);
    _saveQueue();
  }

  Future<void> delete(String entryId, String chapterKey) async {
    final d = state.find(entryId, chapterKey);
    if (d == null) return;
    state = state.copyWith(done: {...state.done}..remove(d.id));
    await DownloadStore.delete(d);
  }

  Future<void> deleteEntry(String entryId) async {
    for (final d in state.forEntry(entryId)) {
      await delete(entryId, d.chapter.key);
    }
  }

  Future<void> deleteAll() async {
    cancelAll();
    state = state.copyWith(done: const {});
    await DownloadStore.deleteAll();
  }

  Future<void> _run() async {
    if (_running || state.waitingForConnection || !state.scanned) return;
    _running = true;
    try {
      while (state.queue.isNotEmpty) {
        final task = state.queue.first;
        state = state.copyWith(activeId: task.id, activeDone: 0, activeTotal: 0);
        try {
          final d = await _download(task);
          if (d != null) {
            state = state.copyWith(done: {...state.done, d.id: d});
          }
        } on _Offline {
          state = state.copyWith(waitingForConnection: true, clearActive: true);
          ref.read(onlineProvider.notifier).state = false;
          return;
        } catch (e) {
          state = state.copyWith(
              failed: {...state.failed, task.id: sourceError(e, task.link.sourceName).message});
        }
        _cancel = null;
        state = state.copyWith(
          queue: [for (final t in state.queue) if (t.id != task.id) t],
          clearActive: true,
        );
        _saveQueue();
      }
    } finally {
      _running = false;
      unawaited(Notifications.endProgress(Notifications.downloadProgressId));
    }
  }

  /// Returns null when cancelled.
  Future<DownloadedChapter?> _download(DownloadTask t) async {
    final source = ref.read(readerSourcesProvider).forLink(t.link);
    final List<String> urls;
    try {
      urls = await source.pages(t.chapter);
    } catch (e) {
      final err = sourceError(e, source.name);
      if (err.offline) throw const _Offline();
      throw err;
    }
    final dir = await DownloadStore.chapterDir(t.entryTitle, t.chapter);
    final files = <String>[];
    var d = DownloadedChapter(
      entryId: t.entryId,
      entryTitle: t.entryTitle,
      sourceId: source.id,
      chapter: t.chapter,
      dir: dir.path,
      files: files,
      complete: false,
    );
    await DownloadStore.writeManifest(d);
    state = state.copyWith(activeTotal: urls.length);
    for (var i = 0; i < urls.length; i++) {
      if (_cancel == t.id) {
        await DownloadStore.delete(d);
        return null;
      }
      try {
        files.add(await DownloadStore.savePage(
            _client, urls[i], i, dir, source.imageHeaders,
            fetcher: source is ImageFetcher ? source as ImageFetcher : null));
      } on SocketException {
        throw const _Offline();
      } on SourceException catch (e) {
        if (e.offline) throw const _Offline();
        rethrow;
      }
      state = state.copyWith(activeDone: i + 1);
      unawaited(Notifications.showProgress(Notifications.downloadProgressId,
          'Downloading ${t.entryTitle} · ${t.chapter.shortLabel}',
          done: i + 1, total: urls.length));
    }
    d = DownloadedChapter(
      entryId: d.entryId,
      entryTitle: d.entryTitle,
      sourceId: d.sourceId,
      chapter: d.chapter,
      dir: d.dir,
      files: files,
      complete: true,
      downloadedAt: DateTime.now(),
    );
    await DownloadStore.writeManifest(d);
    return d;
  }
}

class _Offline implements Exception {
  const _Offline();
}

final downloadsProvider =
    NotifierProvider<DownloadsNotifier, DownloadsState>(DownloadsNotifier.new);

/// Space used by downloads (Settings).
final downloadsSizeProvider = FutureProvider<int>((ref) {
  ref.watch(downloadsProvider.select((s) => s.done.length));
  return DownloadStore.usedBytes();
});
