import 'package:material_ui/material_ui.dart';

import '../theme.dart';

class BarDatum {
  const BarDatum(this.label, this.value, {this.highlight = false});
  final String label;
  final int value;
  final bool highlight;
}

/// Lightweight animated bar chart — no chart package needed. Tap a bar to
/// see its exact value.
class SimpleBarChart extends StatefulWidget {
  const SimpleBarChart({
    super.key,
    required this.data,
    this.height = 160,
    this.color,
    this.labelEvery = 1,
    this.unit = '',
  });

  final List<BarDatum> data;
  final double height;
  final Color? color;

  /// Only label every Nth bar (keeps a 14-day chart readable).
  final int labelEvery;
  final String unit;

  @override
  State<SimpleBarChart> createState() => _SimpleBarChartState();
}

class _SimpleBarChartState extends State<SimpleBarChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = widget.color ?? c.primary;
    final max = widget.data.fold<int>(0, (m, d) => d.value > m ? d.value : m);
    final sel = _selected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 22,
          child: sel == null || sel >= widget.data.length
              ? null
              : Center(
                  child: Text(
                    '${widget.data[sel].label}: ${widget.data[sel].value}${widget.unit}',
                    style: context.text.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
        ),
        SizedBox(
          height: widget.height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < widget.data.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _selected = _selected == i ? null : i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0.0,
                            end: max == 0 ? 0.0 : widget.data[i].value / max,
                          ),
                          duration: Duration(milliseconds: 450 + i * 25),
                          curve: Curves.easeOutCubic,
                          builder: (_, t, _) => Container(
                            height: (widget.height * t).clamp(3.0, widget.height).toDouble(),
                            decoration: BoxDecoration(
                              color: widget.data[i].value == 0
                                  ? c.surfaceContainerHigh
                                  : (sel == null || sel == i)
                                      ? color.withValues(
                                          alpha:
                                              widget.data[i].highlight ? 1 : 0.8)
                                      : color.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < widget.data.length; i++)
              Expanded(
                child: Text(
                  i % widget.labelEvery == 0 ||
                          i == widget.data.length - 1
                      ? widget.data[i].label
                      : '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: context.text.labelSmall?.copyWith(
                    color: c.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A single horizontal bar split into colored segments, with a legend.
class StackedBar extends StatelessWidget {
  const StackedBar({super.key, required this.segments});
  final List<({String label, int value, Color color})> segments;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<int>(0, (a, s) => a + s.value);
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 14,
            child: total == 0
                ? ColoredBox(color: c.surfaceContainerHigh)
                : Row(
                    children: [
                      for (final s in segments)
                        if (s.value > 0)
                          Expanded(
                            flex: s.value,
                            child: ColoredBox(color: s.color),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 16,
          runSpacing: 10,
          children: [
            for (final s in segments)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: s.color, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 6),
                Text(s.label, style: context.text.labelMedium),
                const SizedBox(width: 4),
                Text('${s.value}',
                    style: context.text.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ]),
          ],
        ),
      ],
    );
  }
}
