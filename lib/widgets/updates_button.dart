import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/updates_screen.dart';
import '../state/inbox.dart';

/// Opens the Updates screen (new-chapter alerts).
Future<void> openUpdates(BuildContext context, WidgetRef ref) {
  // The background job may have added alerts.
  ref.read(inboxProvider.notifier).reload();
  return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const UpdatesScreen()));
}

/// The bell in the top bar: opens Updates, with the number of unread
/// new-chapter alerts on it.
class UpdatesButton extends ConsumerWidget {
  const UpdatesButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadAlertsProvider);
    return IconButton(
      tooltip: unread > 0 ? 'Updates · $unread new' : 'Updates',
      onPressed: () => openUpdates(context, ref),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: Icon(unread > 0
            ? Icons.notifications_rounded
            : Icons.notifications_none_rounded),
      ),
    );
  }
}
