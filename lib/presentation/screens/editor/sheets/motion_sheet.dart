/// Ken Burns moves for stills.
///
/// A still on a timeline reads as a freeze unless the camera moves, so this is
/// the one place where the app volunteers an opinion. The move is written as
/// ordinary transform keyframes, which means the user can open the keyframe
/// editor afterwards and change it — nothing here is a special mode.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/usecases/timeline_operations.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class MotionSheet extends ConsumerStatefulWidget {
  const MotionSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<MotionSheet> createState() => _MotionSheetState();
}

class _MotionSheetState extends ConsumerState<MotionSheet> {
  KenBurnsMove _move = KenBurnsMove.zoomIn;
  double _zoom = 0.18;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);

    final selected = editor?.selectedClips ?? const <Clip>[];
    final stills = selected.whereType<ImageClip>().length;
    final animated = selected.where((c) => c.transform.isAnimated).length;

    return ToolSheet(
      title: 'Camera move',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selected.isEmpty
                ? 'Select one or more clips.'
                : stills == selected.length
                ? '${selected.length} still(s) selected.'
                : '${selected.length} clip(s) selected — a move works on '
                      'video too, it just matters less.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SectionHeader(title: 'Move'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final move in KenBurnsMove.values)
                ChoiceChip(
                  selected: _move == move,
                  avatar: Icon(_iconFor(move), size: 18),
                  label: Text(move.label),
                  onSelected: (_) => setState(() => _move = move),
                ),
            ],
          ),

          SectionHeader(
            title: _move.isZoom ? 'Zoom' : 'Travel',
            trailing: Text(
              '${(_zoom * 100).round()}%',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Slider(
            value: _zoom,
            min: 0.04,
            max: 0.6,
            divisions: 28,
            onChanged: (value) => setState(() => _zoom = value),
          ),
          Text(
            _move.isZoom
                ? 'How far the frame pushes in over the clip.'
                : 'A pan needs headroom to travel into, so it scales up by '
                      'this much first. Bigger means further, and softer.',
            style: theme.textTheme.bodySmall,
          ),

          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: selected.isEmpty ? null : _apply,
                  icon: const Icon(Icons.videocam_rounded),
                  label: const Text('Apply move'),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              OutlinedButton(
                onPressed: animated == 0 ? null : _clear,
                child: const Text('Clear'),
              ),
            ],
          ),

          const SectionHeader(title: 'Hero moment'),
          Text(
            'Freezes the frame under the playhead and pushes into it — the '
            '"hold on this" beat, in one action.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          FilledButton.tonalIcon(
            onPressed: selected.isEmpty
                ? null
                : () {
                    ref
                        .read(
                          editorControllerProvider(widget.projectId).notifier,
                        )
                        .heroMoment(zoom: _zoom);
                    unawaited(HapticFeedback.mediumImpact());
                  },
            icon: const Icon(Icons.ac_unit_rounded),
            label: const Text('Freeze and push'),
          ),

          if (animated > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              '$animated of the selected clips already animate. Applying '
              'replaces that move.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(KenBurnsMove move) => switch (move) {
    KenBurnsMove.zoomIn => Icons.zoom_in_rounded,
    KenBurnsMove.zoomOut => Icons.zoom_out_rounded,
    KenBurnsMove.panLeft => Icons.west_rounded,
    KenBurnsMove.panRight => Icons.east_rounded,
    KenBurnsMove.panUp => Icons.north_rounded,
    KenBurnsMove.panDown => Icons.south_rounded,
  };

  void _apply() {
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .applyKenBurns(move: _move, zoom: _zoom);
    unawaited(HapticFeedback.selectionClick());
  }

  void _clear() {
    ref.read(editorControllerProvider(widget.projectId).notifier).clearMotion();
    unawaited(HapticFeedback.selectionClick());
  }
}
