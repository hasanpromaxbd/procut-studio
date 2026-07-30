/// Speed, reverse, and freeze-frame controls for the selected clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/voice_effect.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class SpeedSheet extends ConsumerWidget {
  const SpeedSheet({required this.projectId, super.key});

  final String projectId;

  static const List<double> _presets = [0.1, 0.25, 0.5, 1, 2, 4, 10];

  /// Control points as (position through the clip, rate). Named for what they
  /// look like on screen, not for the maths.
  static const Map<String, List<(double, double)>> _ramps = {
    'Ease in': [(0.0, 0.3), (0.35, 1.0), (1.0, 1.0)],
    'Ease out': [(0.0, 1.0), (0.65, 1.0), (1.0, 0.3)],
    'Slow middle': [(0.0, 1.6), (0.5, 0.35), (1.0, 1.6)],
    'Fast middle': [(0.0, 0.5), (0.5, 2.5), (1.0, 0.5)],
    'Bullet time': [(0.0, 1.0), (0.4, 0.15), (0.6, 0.15), (1.0, 1.0)],
    'Speed up': [(0.0, 0.5), (1.0, 3.0)],
  };

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
              onChanged: (value) => controller.setPreservePitch(
                preserve: value,
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Shift', style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  child: Slider(
                    value: clip.pitchSemitones.clamp(-12.0, 12.0),
                    min: -12,
                    max: 12,
                    divisions: 48,
                    label:
                        '${clip.pitchSemitones >= 0 ? '+' : ''}'
                        '${clip.pitchSemitones.toStringAsFixed(1)} st',
                    onChanged: controller.setPitch,
                  ),
                ),
              ],
            ),
            const SectionHeader(title: 'Crossfade into the next clip'),
            Wrap(
              spacing: Spacing.xs,
              children: [
                for (final ms in [300, 500, 1000, 2000])
                  ActionChip(
                    label: Text('${ms / 1000}s'),
                    onPressed: () => controller.setAudioCrossfade(
                      Duration(milliseconds: ms),
                    ),
                  ),
              ],
            ),
            Text(
              'Equal-power fades either side of the cut — the next audio '
              'clip must be touching this one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SectionHeader(title: 'Voice'),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final effect in VoiceEffect.values)
                  ChoiceChip(
                    selected: clip.voiceEffect == effect,
                    label: Text(effect.label),
                    tooltip: effect.blurb,
                    onSelected: (_) => controller.setVoiceEffect(effect),
                  ),
              ],
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
          const SectionHeader(title: 'Speed ramp'),
          Text(
            'A ramp varies the rate across the clip. The clip is re-timed to '
            'consume the same source material, so the cut after it moves.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final ramp in _ramps.entries)
                ActionChip(
                  label: Text(ramp.key),
                  onPressed: () => controller.setSpeedRamp(ramp.value),
                ),
              if (clip.hasSpeedRamp)
                ActionChip(
                  avatar: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('Clear ramp'),
                  onPressed: () => controller.setSpeedRamp(const []),
                ),
            ],
          ),
          if (clip.hasSpeedRamp)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(
                'Rendered as stepped segments — FFmpeg cannot express a '
                'continuous ramp, so a very long one may show slight stepping.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
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
