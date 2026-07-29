/// The audio mixer: per-track level, mute, solo and ducking.
///
/// Ducking lives here rather than on a clip because it is a relationship
/// between two tracks, and it has to survive every cut made to either of them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/ducking.dart';
import '../../../../domain/entities/track.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class MixerSheet extends ConsumerWidget {
  const MixerSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final theme = Theme.of(context);

    final tracks = editor?.timeline.tracks
            .where((t) => t.type == TrackType.audio || t.type == TrackType.video)
            .toList() ??
        const <Track>[];

    return ToolSheet(
      title: 'Mixer',
      child: tracks.isEmpty
          ? Text(
              'No audio tracks yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final track in tracks)
                  _TrackStrip(
                    projectId: projectId,
                    track: track,
                    others: tracks.where((t) => t.id != track.id).toList(),
                  ),
              ],
            ),
    );
  }
}

class _TrackStrip extends ConsumerWidget {
  const _TrackStrip({
    required this.projectId,
    required this.track,
    required this.others,
  });

  final String projectId;
  final Track track;
  final List<Track> others;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final duck = track.ducking;

    return Card(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Color(track.type.colorValue),
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    track.displayName,
                    style: theme.textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  isSelected: track.solo,
                  tooltip: 'Solo',
                  icon: const Text('S'),
                  selectedIcon: Text(
                    'S',
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onPressed: () => controller.toggleTrackSolo(track.id),
                ),
                IconButton(
                  tooltip: track.muted ? 'Unmute' : 'Mute',
                  icon: Icon(
                    track.muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                  ),
                  onPressed: () => controller.toggleTrackMute(track.id),
                ),
              ],
            ),

            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: track.volume.clamp(0.0, 2.0),
                    max: 2,
                    divisions: 40,
                    label: '${(track.volume * 100).round()}%',
                    onChanged: (value) =>
                        controller.setTrackVolume(track.id, value),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${(track.volume * 100).round()}%',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),

            if (others.isNotEmpty) ...[
              const Divider(height: Spacing.lg),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Duck under another track',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Switch(
                    value: duck != null,
                    onChanged: (on) => controller.setTrackDucking(
                      track.id,
                      on ? Ducking(keyTrackId: others.first.id) : null,
                    ),
                  ),
                ],
              ),
              if (duck != null) ...[
                const SizedBox(height: Spacing.sm),
                DropdownButtonFormField<String>(
                  initialValue: others.any((t) => t.id == duck.keyTrackId)
                      ? duck.keyTrackId
                      : others.first.id,
                  decoration: const InputDecoration(
                    labelText: 'Steps aside for',
                    isDense: true,
                  ),
                  items: [
                    for (final other in others)
                      DropdownMenuItem(
                        value: other.id,
                        child: Text(other.displayName),
                      ),
                  ],
                  onChanged: (value) => value == null
                      ? null
                      : controller.setTrackDucking(
                          track.id,
                          duck.copyWith(keyTrackId: value),
                        ),
                ),
                _DuckSlider(
                  label: 'Strength',
                  value: duck.strength,
                  min: 1,
                  max: 20,
                  format: (v) => '${v.toStringAsFixed(1)}:1',
                  onChanged: (v) => controller.setTrackDucking(
                    track.id,
                    duck.copyWith(strength: v),
                  ),
                ),
                _DuckSlider(
                  label: 'Sensitivity',
                  value: duck.sensitivity,
                  min: 0.005,
                  max: 0.4,
                  format: (v) => v.toStringAsFixed(3),
                  onChanged: (v) => controller.setTrackDucking(
                    track.id,
                    duck.copyWith(sensitivity: v),
                  ),
                ),
                _DuckSlider(
                  label: 'Release',
                  value: duck.release.inMilliseconds.toDouble(),
                  min: 50,
                  max: 2000,
                  format: (v) => '${v.round()} ms',
                  onChanged: (v) => controller.setTrackDucking(
                    track.id,
                    duck.copyWith(
                      release: Duration(milliseconds: v.round()),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'About ${duck.reductionDbFor(-12).toStringAsFixed(1)} dB '
                  'quieter under normal speech. The exact amount follows how '
                  'loud the other track is — that is what makes it sound like '
                  'a hand on the fader rather than a gate.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _DuckSlider extends StatelessWidget {
  const _DuckSlider({
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
          width: 86,
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
          width: 62,
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
