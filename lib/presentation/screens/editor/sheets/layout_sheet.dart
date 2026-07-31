/// Layer layout: position, size, split-screen arrangements and PiP dressing.
///
/// One sheet because they are one question — "where does this layer sit and
/// what does it look like at the edges". Splitting position from rounding
/// would mean two trips for what is visually a single decision.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/layer_frame.dart';
import '../../../../domain/usecases/timeline_operations.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class LayoutSheet extends ConsumerWidget {
  const LayoutSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final theme = Theme.of(context);

    final selected = editor?.selectedClips ?? const [];
    final primary = selected.isEmpty ? null : selected.first;
    final frame = primary?.frame ?? LayerFrame.none;
    final transform = primary?.transform;

    return ToolSheet(
      title: 'Layout',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (primary == null)
            Text(
              'Select a clip to position it.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

          const SectionHeader(title: 'Arrange'),
          Text(
            'Applied in timeline order — the first selected clip takes the '
            'first slot.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final layout in SplitLayout.values)
                ActionChip(
                  avatar: _LayoutGlyph(layout: layout),
                  label: Text(layout.label),
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          controller.applyLayout(layout);
                          unawaited(HapticFeedback.selectionClick());
                        },
                ),
            ],
          ),
          if (selected.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                '${selected.length} selected.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          if (transform != null) ...[
            const SectionHeader(title: 'Position'),
            _Nudge(
              label: 'Size',
              value: transform.scaleX.staticValue,
              min: 0.1,
              max: 3,
              format: (v) => '${(v * 100).round()}%',
              onChanged: controller.setLayerScale,
            ),
            _Nudge(
              label: 'Across',
              value: transform.x.staticValue,
              min: -0.6,
              max: 0.6,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => controller.setLayerPosition(x: v),
            ),
            _Nudge(
              label: 'Down',
              value: transform.y.staticValue,
              min: -0.6,
              max: 0.6,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => controller.setLayerPosition(y: v),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: controller.resetLayerPlacement,
                child: const Text('Reset to full frame'),
              ),
            ),
          ],

          const SectionHeader(title: 'Edges'),
          _Nudge(
            label: 'Rounding',
            value: frame.cornerRadius,
            min: 0,
            max: 0.5,
            format: (v) => v < 0.005 ? 'square' : '${(v * 200).round()}%',
            onChanged: (v) =>
                controller.setLayerFrame(frame.copyWith(cornerRadius: v)),
          ),
          _Nudge(
            label: 'Border',
            value: frame.borderWidth,
            min: 0,
            max: 0.12,
            format: (v) => v < 0.002 ? 'none' : '${(v * 100).toStringAsFixed(1)}%',
            onChanged: (v) =>
                controller.setLayerFrame(frame.copyWith(borderWidth: v)),
          ),
          if (frame.hasBorder) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Text('Colour', style: theme.textTheme.bodySmall),
                const SizedBox(width: Spacing.md),
                for (final colour in const [
                  0xFFFFFFFF,
                  0xFF000000,
                  0xFFE0324B,
                  0xFF2FD4A8,
                  0xFFF5C542,
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: Spacing.sm),
                    child: GestureDetector(
                      onTap: () => controller.setLayerFrame(
                        frame.copyWith(borderColor: colour),
                      ),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(colour),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: frame.borderColor == colour
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                            width: frame.borderColor == colour ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],

          const SizedBox(height: Spacing.sm),
          Text(
            'Rounding and border follow the layer, not the frame — they stay '
            'correct wherever you move it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A tiny diagram of the arrangement — faster to read than its name.
class _LayoutGlyph extends StatelessWidget {
  const _LayoutGlyph({required this.layout});

  final SplitLayout layout;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    height: 18,
    child: CustomPaint(
      painter: _GlyphPainter(
        layout: layout,
        colour: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.layout, required this.colour});

  final SplitLayout layout;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colour.withValues(alpha: 0.75);
    for (final cell in layout.cells) {
      final w = size.width * cell.scale;
      final h = size.height * cell.scale;
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(
            size.width / 2 + cell.x * size.width,
            size.height / 2 + cell.y * size.height,
          ),
          width: w - 1,
          height: h - 1,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.layout != layout || old.colour != colour;
}

class _Nudge extends StatelessWidget {
  const _Nudge({
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
          width: 74,
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
          width: 58,
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
