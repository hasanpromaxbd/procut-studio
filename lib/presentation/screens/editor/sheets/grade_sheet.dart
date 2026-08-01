/// The grading panel.
///
/// Grading has its own sheet rather than living in the generic effect
/// inspector because fourteen sliders in a column is not a grading tool. The
/// wheels are the difference: a hue push is a direction and a distance, and
/// two numbered sliders per zone hide that behind arithmetic the user has to
/// do in their head.
///
/// Everything here writes into one [EffectType.colorGrade] effect on the
/// selected clip, created on first touch. Looks write the same parameters the
/// wheels do, so applying one and then adjusting it is the ordinary path, not
/// an escape hatch.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/effect.dart';
import '../../../../engine/effects/grade_looks.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class GradeSheet extends ConsumerWidget {
  const GradeSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched, not read: applying a look has to move every wheel on screen.
    ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final theme = Theme.of(context);

    final grade = controller.selectedGrade;
    final hasClip = ref.read(editorControllerProvider(projectId))?.selectedClipId != null;

    if (!hasClip) {
      return const ToolSheet(
        title: 'Grade',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Text('Select a clip to grade it.'),
        ),
      );
    }

    double value(String key, [double fallback = 0]) =>
        grade?.param(key, fallback: fallback) ?? fallback;

    void set(Map<String, double> values, String label) =>
        controller.setGradeValues(values, label: label);

    return ToolSheet(
      title: 'Grade',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Looks'),
          Text(
            'A starting point, not a lock — every control below moves to '
            'where the look put it, and stays adjustable.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final look in GradeLooks.all)
                ActionChip(
                  label: Text(look.label),
                  tooltip: look.description,
                  onPressed: () {
                    set(look.values, 'apply ${look.label.toLowerCase()}');
                    unawaited(HapticFeedback.selectionClick());
                  },
                ),
            ],
          ),

          const SectionHeader(title: 'Colour wheels'),
          Row(
            children: [
              Expanded(
                child: _Wheel(
                  label: 'Lift',
                  hint: 'Shadows',
                  x: value('liftX'),
                  y: value('liftY'),
                  onChanged: (x, y) => set({'liftX': x, 'liftY': y}, 'lift'),
                ),
              ),
              Expanded(
                child: _Wheel(
                  label: 'Gamma',
                  hint: 'Mid-tones',
                  x: value('gammaX'),
                  y: value('gammaY'),
                  onChanged: (x, y) => set({'gammaX': x, 'gammaY': y}, 'gamma'),
                ),
              ),
              Expanded(
                child: _Wheel(
                  label: 'Gain',
                  hint: 'Highlights',
                  x: value('gainX'),
                  y: value('gainY'),
                  onChanged: (x, y) => set({'gainX': x, 'gainY': y}, 'gain'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Drag to push that range towards a hue. Double-tap a wheel to '
            'centre it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SectionHeader(title: 'White balance'),
          _Knob(
            label: 'Warmth',
            value: value('warmth'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'warmth': v}, 'warmth'),
          ),
          _Knob(
            label: 'Tint',
            value: value('tint'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'tint': v}, 'tint'),
          ),

          const SectionHeader(title: 'Tone'),
          _Knob(
            label: 'Contrast',
            value: value('contrast'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'contrast': v}, 'contrast'),
          ),
          _Knob(
            label: 'Pivot',
            value: value('pivot', 0.5),
            min: 0.2,
            max: 0.8,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => set({'pivot': v}, 'pivot'),
          ),
          _Knob(
            label: 'Shadows',
            value: value('shadows'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'shadows': v}, 'shadows'),
          ),
          _Knob(
            label: 'Highlights',
            value: value('highlights'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'highlights': v}, 'highlights'),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Contrast pivots around the level you set — raise the pivot and it '
            'protects the shadows, lower it and it protects the highlights.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SectionHeader(title: 'Saturation'),
          _Knob(
            label: 'Vibrance',
            value: value('vibrance'),
            min: -1,
            max: 1,
            format: _signed,
            onChanged: (v) => set({'vibrance': v}, 'vibrance'),
          ),
          _Knob(
            label: 'Saturation',
            value: value('saturation', 1),
            min: 0,
            max: 2,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) => set({'saturation': v}, 'saturation'),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Vibrance leans on the colours that are already dull, which is why '
            'it can be pushed much further than saturation before skin goes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: grade == null
                      ? null
                      : () => set(GradeLooks.neutral.values, 'reset grade'),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset'),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: grade == null ? null : controller.clearGrade,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _signed(double v) =>
      '${v >= 0 ? '+' : ''}${(v * 100).round()}';
}

/// A colour wheel: angle is hue, distance from the centre is how far to push.
class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.label,
    required this.hint,
    required this.x,
    required this.y,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final double x;
  final double y;
  final void Function(double x, double y) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final size = math.min(constraints.maxWidth, 108.0);
              return SizedBox(
                width: size,
                height: size,
                child: GestureDetector(
                  onDoubleTap: () {
                    onChanged(0, 0);
                    unawaited(HapticFeedback.selectionClick());
                  },
                  onPanStart: (d) => _emit(d.localPosition, size),
                  onPanUpdate: (d) => _emit(d.localPosition, size),
                  child: CustomPaint(
                    painter: _WheelPainter(
                      x: x,
                      y: y,
                      ring: theme.colorScheme.outlineVariant,
                      puck: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: Spacing.xs),
          Text(label, style: theme.textTheme.labelMedium),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Screen y grows downwards and the model's does not, hence the negation —
  /// dragging towards the top of the wheel has to mean "up" in both.
  void _emit(Offset local, double size) {
    final radius = size / 2;
    var dx = (local.dx - radius) / radius;
    var dy = -(local.dy - radius) / radius;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length > 1) {
      dx /= length;
      dy /= length;
    }
    onChanged(dx, dy);
  }
}

class _WheelPainter extends CustomPainter {
  const _WheelPainter({
    required this.x,
    required this.y,
    required this.ring,
    required this.puck,
  });

  final double x;
  final double y;
  final Color ring;
  final Color puck;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // The hue at a point has to match what a push there actually does. In the
    // compiler red sits at 90°, green at 210° and blue at 330°, measured with
    // y upwards; on canvas y runs downwards, so the screen angle is negated
    // before it becomes a hue.
    final colours = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= 12; i++) {
      final screenDegrees = i * 30.0;
      final hue = (-screenDegrees - 90) % 360;
      colours.add(HSVColor.fromAHSV(1, hue, 0.85, 1).toColor());
      stops.add(i / 12);
    }

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = SweepGradient(colors: colours, stops: stops).createShader(
          Rect.fromCircle(center: centre, radius: radius),
        ),
    );
    // Desaturating towards the middle is not decoration: it shows that the
    // centre is neutral, which is the one position that means "off".
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF202020),
            const Color(0x00202020),
          ],
        ).createShader(Rect.fromCircle(center: centre, radius: radius)),
    );
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ring,
    );

    final position = centre + Offset(x * radius, -y * radius);
    canvas.drawCircle(position, 7, Paint()..color = puck.withValues(alpha: 0.9));
    canvas.drawCircle(
      position,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF101010),
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      old.x != x || old.y != y || old.ring != ring || old.puck != puck;
}

class _Knob extends StatelessWidget {
  const _Knob({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            format(value),
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
