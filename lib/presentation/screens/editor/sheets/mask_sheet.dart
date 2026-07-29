/// Shape mask controls for the selected clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/keyframe.dart';
import '../../../../domain/entities/mask.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class MaskSheet extends ConsumerWidget {
  const MaskSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final found = clipId == null ? null : editor!.timeline.findClip(clipId);
    final clip = found?.$2;

    if (clip == null) {
      return const ToolSheet(
        title: 'Mask',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Text('Select a clip to mask.'),
        ),
      );
    }

    final mask = clip.mask;

    return ToolSheet(
      title: 'Mask',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Masks are animatable — set a keyframe on the position to make one '
            'follow a subject.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SectionHeader(title: 'Shape'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final shape in MaskShape.values)
                ChoiceChip(
                  label: Text(shape.label),
                  selected: mask.shape == shape,
                  onSelected: (_) => controller.setMask(
                    shape == MaskShape.none
                        ? Mask.none
                        : mask.copyWith(shape: shape),
                  ),
                ),
            ],
          ),

          if (mask.isActive) ...[
            const SectionHeader(title: 'Position'),
            _MaskSlider(
              label: 'Centre X',
              value: mask.centerX,
              min: -0.5,
              max: 1.5,
              onChanged: (v) =>
                  controller.setMask(mask.copyWith(centerX: mask.centerX.withStatic(v))),
            ),
            _MaskSlider(
              label: 'Centre Y',
              value: mask.centerY,
              min: -0.5,
              max: 1.5,
              onChanged: (v) =>
                  controller.setMask(mask.copyWith(centerY: mask.centerY.withStatic(v))),
            ),

            const SectionHeader(title: 'Size'),
            if (mask.shape != MaskShape.linear)
              _MaskSlider(
                label: 'Width',
                value: mask.width,
                min: 0.02,
                max: 1.5,
                onChanged: (v) =>
                    controller.setMask(mask.copyWith(width: mask.width.withStatic(v))),
              ),
            _MaskSlider(
              label: mask.shape == MaskShape.linear ? 'Position' : 'Height',
              value: mask.height,
              min: 0.02,
              max: 1.5,
              onChanged: (v) =>
                  controller.setMask(mask.copyWith(height: mask.height.withStatic(v))),
            ),

            const SectionHeader(title: 'Edge'),
            _MaskSlider(
              label: 'Feather',
              value: mask.feather,
              min: 0,
              max: 0.5,
              onChanged: (v) => controller
                  .setMask(mask.copyWith(feather: mask.feather.withStatic(v))),
            ),
            _MaskSlider(
              label: 'Rotation',
              value: mask.rotation,
              min: 0,
              max: 360,
              formatter: (v) => '${v.round()}°',
              onChanged: (v) => controller
                  .setMask(mask.copyWith(rotation: mask.rotation.withStatic(v))),
            ),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Invert'),
              subtitle: const Text('Keep the outside instead'),
              value: mask.inverted,
              onChanged: (v) => controller.setMask(mask.copyWith(inverted: v)),
            ),

            const SizedBox(height: Spacing.md),
            Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Text(
                  'The preview draws the mask with a GPU shader; the export '
                  'rebuilds the same shape as an alpha channel. They use the '
                  'same distance maths, so what you see is what renders.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MaskSlider extends StatelessWidget {
  const _MaskSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.formatter,
  });

  final String label;
  final AnimatableDouble value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String Function(double)? formatter;

  @override
  Widget build(BuildContext context) => LabeledSlider(
    label: value.isAnimated ? '$label  ·  animated' : label,
    value: value.staticValue,
    min: min,
    max: max,
    formatter: formatter ?? (v) => v.toStringAsFixed(2),
    onChanged: onChanged,
  );
}
