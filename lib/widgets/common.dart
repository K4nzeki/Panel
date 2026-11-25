import 'package:material_ui/material_ui.dart';

import '../models/entry.dart';
import '../theme.dart';

/// Cover art with a tasteful placeholder (title initial on a tinted card)
/// while loading, when missing, or when the image fails.
class CoverImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(title: title);
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: (u == null || u.isEmpty)
            ? placeholder
            : Image.network(
                u,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync) return child;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: frame == null ? placeholder : child,
                  );
                },
              ),
      ),
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
