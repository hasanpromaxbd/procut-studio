/// Speed, reverse, and freeze-frame controls for the selected clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class SpeedSheet extends ConsumerWidget {
  const SpeedSheet({required this.projectId, super.key});

  final String projectId;

  static const List<double> _presets = [0.1, 0.25, 0.5, 1, 2, 4, 10];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final theme = Theme.of(context);

    final found = editor?.selectedClipId == null
        ? null
        : editor!.timeline.findClip(editor.selectedClipId!);
    final clip = found?.$2;

    if (clip is! MediaClip) {
      return const ToolSheet(
        title: 'Speed',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Text('Select a video or audio clip to change its speed.'),
        ),
      );
    }

    return ToolSheet(
      title: 'Speed',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final preset in _presets)
                ChoiceChip(
                  label: Text('${_format(preset)}×'),
                  selected: (clip.speed - preset).abs() < 0.001,
                  onSelected: (_) => controller.setSpeed(preset),
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          LabeledSlider(
            label: 'Custom',
            value: clip.speed,
            min: AppConstants.minClipSpeed,
            max: AppConstants.maxClipSpeed,
            formatter: (v) => '${_format(v)}×',
            onChanged: controller.setSpeed,
            onReset: () => controller.setSpeed(1),
          ),
          const Divider(height: Spacing.xxl),
          _InfoRow(
            label: 'Source length',
            value: TimeUtils.formatShort(clip.sourceDuration),
          ),
          _InfoRow(
            label: 'Timeline length',
            value: TimeUtils.formatShort(clip.duration),
          ),
          if (clip is AudioClip) ...[
            const SectionHeader(title: 'Pitch'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep original pitch'),
              subtitle: const Text(
                'Off makes speed changes sound like a tape machine',
              ),
              value: clip.preservePitch,
              onChanged: (_) {},
            ),
          ],
          const SectionHeader(title: 'Direction'),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: controller.reverseSelected,
                  icon: Icon(
                    clip.reversed
                        ? Icons.fast_forward_rounded
                        : Icons.fast_rewind_rounded,
                  ),
                  label: Text(clip.reversed ? 'Play forward' : 'Reverse'),
                ),
              ),
            ],
          ),
          if (clip.reversed)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(
                'Reversed clips are rendered in a separate pass before export, '
                'so they take a little longer.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (clip is VideoClip) ...[
            const SectionHeader(title: 'Freeze frame'),
            OutlinedButton.icon(
              onPressed: () {
                controller.freezeFrameAtPlayhead();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.ac_unit_rounded),
              label: const Text('Hold this frame for 2s'),
            ),
          ],
        ],
      ),
    );
  }

  static String _format(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
