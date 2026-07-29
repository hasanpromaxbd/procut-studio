/// Slip, slide and roll.
///
/// These three are the difference between arranging clips and editing. They
/// are hard to express as a drag on a phone — a slip and a trim start out as
/// the same gesture on the same pixel — so they get explicit nudge controls
/// with a readout of what each one will do, rather than a hidden modifier.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

enum _TrimMode {
  slip(
    'Slip',
    Icons.swap_horiz_rounded,
    'The clip stays put; a different part of the take plays.',
  ),
  slide(
    'Slide',
    Icons.compare_arrows_rounded,
    'The clip moves; the neighbours give and take to fit.',
  ),
  roll(
    'Roll',
    Icons.import_export_rounded,
    'One cut moves; one clip gains what the other loses.',
  );

  const _TrimMode(this.label, this.icon, this.blurb);
  final String label;
  final IconData icon;
  final String blurb;
}

class TrimSheet extends ConsumerStatefulWidget {
  const TrimSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<TrimSheet> createState() => _TrimSheetState();
}

class _TrimSheetState extends ConsumerState<TrimSheet> {
  _TrimMode _mode = _TrimMode.slip;
  bool _rollAtStart = false;

  /// Nudge size in frames. Frames, not milliseconds — an editor thinks in
  /// frames, and a sub-frame nudge would snap away to nothing anyway.
  int _step = 1;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);
    final fps = editor?.timeline.fps ?? 30;
    final nudge = TimeUtils.frameToDuration(_step, fps);

    final clip = editor?.selectedClipId == null
        ? null
        : editor!.timeline.findClip(editor.selectedClipId!)?.$2;

    return ToolSheet(
      title: 'Trim',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (clip == null)
            Text(
              'Select a clip to trim.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

          SegmentedButton<_TrimMode>(
            segments: [
              for (final mode in _TrimMode.values)
                ButtonSegment(
                  value: mode,
                  icon: Icon(mode.icon),
                  label: Text(mode.label),
                ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) =>
                setState(() => _mode = value.first),
          ),
          const SizedBox(height: Spacing.md),
          Text(_mode.blurb, style: theme.textTheme.bodySmall),

          if (_mode == _TrimMode.roll) ...[
            const SizedBox(height: Spacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _rollAtStart,
              title: const Text('Roll the head cut'),
              subtitle: Text(
                _rollAtStart
                    ? 'The cut before this clip'
                    : 'The cut after this clip',
                style: theme.textTheme.bodySmall,
              ),
              onChanged: (value) => setState(() => _rollAtStart = value),
            ),
          ],

          const SectionHeader(title: 'Step'),
          Wrap(
            spacing: Spacing.sm,
            children: [
              for (final frames in [1, 5, fps, fps * 5])
                ChoiceChip(
                  selected: _step == frames,
                  label: Text(_stepLabel(frames, fps)),
                  onSelected: (_) => setState(() => _step = frames),
                ),
            ],
          ),

          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NudgeButton(
                icon: Icons.keyboard_double_arrow_left_rounded,
                label: '−${_stepLabel(_step, fps)}',
                enabled: clip != null,
                onPressed: () => _nudge(-nudge),
              ),
              _NudgeButton(
                icon: Icons.keyboard_double_arrow_right_rounded,
                label: '+${_stepLabel(_step, fps)}',
                enabled: clip != null,
                onPressed: () => _nudge(nudge),
              ),
            ],
          ),

          if (clip != null) ...[
            const SectionHeader(title: 'This clip'),
            _Readout(clip: clip, fps: fps),
          ],

          if (editor?.errorMessage != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              editor!.errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _stepLabel(int frames, int fps) {
    if (frames == 1) return '1 frame';
    if (frames < fps) return '$frames frames';
    final seconds = frames ~/ fps;
    return '${seconds}s';
  }

  void _nudge(Duration by) {
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );
    switch (_mode) {
      case _TrimMode.slip:
        controller.slipSelected(by);
      case _TrimMode.slide:
        controller.slideSelected(by);
      case _TrimMode.roll:
        controller.rollSelected(by, atStart: _rollAtStart);
    }
    unawaited(HapticFeedback.selectionClick());
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.clip, required this.fps});

  final Clip clip;
  final int fps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('Position', TimeUtils.formatSmpte(clip.start, fps)),
      ('Length', TimeUtils.formatSmpte(clip.duration, fps)),
      if (clip is MediaClip && clip is! ImageClip)
        (
          'Source in',
          TimeUtils.formatSmpte((clip as MediaClip).sourceIn, fps),
        ),
    ];

    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: theme.textTheme.bodySmall),
                ),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: enabled ? onPressed : null,
    icon: Icon(icon),
    label: Text(label),
  );
}
