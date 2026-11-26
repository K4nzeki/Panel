import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/inbox.dart';

/// The Updates tab: "new chapter" alerts, newest first. Reloads when the
/// app comes back to the screen, since the background job may have added
/// some while it was closed.
class InboxNotifier extends Notifier<List<ChapterAlert>> {
  AppLifecycleListener? _lifecycle;

  @override
  List<ChapterAlert> build() {
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(reload()));
    ref.onDispose(() => _lifecycle?.dispose());
    unawaited(Future.microtask(reload));
    return const [];
  }

  Future<void> reload() async {
    state = await Inbox.load();
  }

  /// Applies [change] to what's saved now (the background job may have
  /// added alerts since the last load), then saves.
  Future<void> _update(
      List<ChapterAlert> Function(List<ChapterAlert> current) change) async {
    final next = change(await Inbox.load());
    state = next;
    await Inbox.save(next);
  }

  Future<void> markRead(String entryId) async {
    if (!state.any((a) => a.entryId == entryId && !a.read)) return;
    await _update((list) => [
          for (final a in list)
            a.entryId == entryId ? a.copyWith(read: true) : a,
        ]);
  }

  Future<void> markAllRead() =>
      _update((list) => [for (final a in list) a.copyWith(read: true)]);

  Future<void> remove(String entryId) {
    // Drop it right away: a swiped-away tile must leave the list this frame.
    state = [for (final a in state) if (a.entryId != entryId) a];
    return _update((list) => [for (final a in list) if (a.entryId != entryId) a]);
  }

  /// Puts back an alert removed by mistake (the snackbar's Undo).
  Future<void> restore(ChapterAlert alert, int index) => _update((list) {
        final at = index < 0 ? 0 : (index > list.length ? list.length : index);
        return [...list]..insert(at, alert);
      });

  Future<void> clear() => _update((_) => const []);
}

final inboxProvider =
    NotifierProvider<InboxNotifier, List<ChapterAlert>>(InboxNotifier.new);

/// Badge on the Updates tab.
final unreadAlertsProvider = Provider<int>(
    (ref) => ref.watch(inboxProvider).where((a) => !a.read).length);
