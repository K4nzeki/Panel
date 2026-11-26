import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry.dart';
import '../services/cover_cache.dart';
import '../state/providers.dart';
import '../theme.dart';

/// Cover art with a tasteful placeholder (title initial on a tinted card)
/// while loading, when missing, or when the image fails.
///
/// Covers are saved on the phone ([CoverCache]) the first time they load
/// and always shown from there afterwards, so they work offline. The
/// placeholder only stays when a cover was never saved and there's no
/// connection; it tries again when the connection comes back.
class CoverImage extends ConsumerWidget {
  const CoverImage({
    super.key,
    required this.url,
    required this.title,
    this.width,
    this.height,
    this.radius = 12,
  });

  final String? url;
  final String title;
  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = _Placeholder(title: title);
    final u = url?.trim();
    // A cover that failed while offline loads again once you're back.
    final online = ref.watch(onlineProvider);
    final Widget child;
    if (u == null || u.isEmpty) {
      child = placeholder;
    } else {
      Widget frame(BuildContext context, Widget child, int? frame, bool sync) {
        if (sync) return child;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: frame == null ? placeholder : child,
        );
      }

      final saved = CoverCache.savedSync(u);
      final ImageProvider remote =
          CoverCache.supported ? CachedCoverProvider(u) : NetworkImage(u);
      child = saved != null
          // Saved: straight from the phone, no network involved.
          ? Image.file(
              saved,
              key: ValueKey('file:$u'),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: frame,
            )
          : Image(
              key: ValueKey('net:$u#$online'),
              image: remote,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: frame,
            );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final initial = title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.primary.withValues(alpha: 0.28),
            c.tertiary.withValues(alpha: 0.18),
          ],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: context.text.headlineSmall?.copyWith(
            color: c.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// Small rounded label showing a reading status in its color.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key, this.dense = false});
  final EntryStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = context.statusColors.of(status);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: context.text.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Neutral tag (e.g. the title's type).
class TagChip extends StatelessWidget {
  const TagChip(this.label, {super.key, this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: context.text.labelSmall?.copyWith(
              color: c.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin rounded progress bar. When [value] is null (unknown total) it
/// shows nothing.
class ThinProgress extends StatelessWidget {
  const ThinProgress({super.key, required this.value, this.color});
  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v == null) return const SizedBox.shrink();
    final c = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: v),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        builder: (_, val, _) => LinearProgressIndicator(
          value: val,
          minHeight: 5,
          backgroundColor: c.surfaceContainerHigh,
          color: color ?? c.primary,
        ),
      ),
    );
  }
}

/// Friendly empty / error state with an optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 36, color: c.primary),
            ),
            const SizedBox(height: 20),
            Text(title,
                style: context.text.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              message,
              style: context.text.bodyMedium
                  ?.copyWith(color: c.onSurfaceVariant, height: 1.4),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Section header used on Stats / Profile.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text.toUpperCase(),
                style: context.text.labelMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

void showSnack(BuildContext context, String message,
    {SnackBarAction? action, bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(
      message,
      style: error ? TextStyle(color: context.colors.onErrorContainer) : null,
    ),
    action: action,
    backgroundColor: error ? context.colors.errorContainer : null,
    duration: Duration(seconds: action != null ? 5 : 3),
  ));
}

DateTime _lastOfflineToast = DateTime.fromMillisecondsSinceEpoch(0);

/// A short "you're offline" toast at the bottom: goes away by itself after
/// a few seconds (or with its close button). Shown at most every 2 minutes
/// unless [force] (you just tried something that needs a connection).
void showOfflineToast(BuildContext context, {bool force = false}) {
  final now = DateTime.now();
  if (!force &&
      now.difference(_lastOfflineToast) < const Duration(minutes: 2)) {
    return;
  }
  _lastOfflineToast = now;
  final c = context.colors;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  // No action button: snack bars with one may stay until tapped.
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    showCloseIcon: true,
    duration: const Duration(seconds: 4),
    content: Row(children: [
      Icon(Icons.cloud_off_rounded, size: 18, color: c.onInverseSurface),
      const SizedBox(width: 10),
      const Expanded(child: Text("You're offline — showing cached content")),
    ]),
  ));
}
