/// Voice-over recording, with a live level meter.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../engine/audio/voice_recorder.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class RecordSheet extends ConsumerStatefulWidget {
  const RecordSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends ConsumerState<RecordSheet> {
  late final VoiceRecorder _recorder;

  StreamSubscription<RecordingLevel>? _levelSub;
  Timer? _ticker;

  RecordingLevel? _level;
  Duration _elapsed = Duration.zero;
  bool _recording = false;
  bool _paused = false;
  bool _busy = false;
  bool _clippedAtAnyPoint = false;
  String? _error;

  /// Where on the timeline the recording will land — captured when the sheet
  /// opens so it does not shift if the playhead moves underneath.
  late final Duration _insertAt;

  @override
  void initState() {
    super.initState();
    _recorder = VoiceRecorder(paths: ref.read(pathServiceProvider));
    _insertAt = ref.read(playheadControllerProvider).position;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_levelSub?.cancel());
    // Disposing cancels an in-flight recording and deletes the partial file.
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await _recorder.start();
    if (!mounted) return;

    result.fold(
      (_) {
        HapticFeedback.mediumImpact();
        _levelSub = _recorder.levels.listen((level) {
          if (!mounted) return;
          setState(() {
            _level = level;
            if (level.isClipping) _clippedAtAnyPoint = true;
          });
        });
        _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (mounted) setState(() => _elapsed = _recorder.elapsed);
        });
        setState(() {
          _recording = true;
          _paused = false;
          _busy = false;
        });
      },
      (failure) => setState(() {
        _busy = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _togglePause() async {
    if (_paused) {
      await _recorder.resume();
    } else {
      await _recorder.pause();
    }
    if (mounted) setState(() => _paused = !_paused);
  }

  Future<void> _stopAndInsert() async {
    setState(() => _busy = true);
    _ticker?.cancel();
    await _levelSub?.cancel();
    _levelSub = null;

    final result = await _recorder.stop();
    if (!mounted) return;

    await result.fold(
      (path) async {
        await ref
            .read(editorControllerProvider(widget.projectId).notifier)
            .addMedia([path], at: _insertAt);
        if (mounted) {
          unawaited(HapticFeedback.selectionClick());
          Navigator.of(context).pop();
        }
      },
      (failure) async {
        setState(() {
          _busy = false;
          _recording = false;
          _error = failure.message;
        });
      },
    );
  }

  Future<void> _discard() async {
    _ticker?.cancel();
    await _levelSub?.cancel();
    _levelSub = null;
    await _recorder.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ToolSheet(
      title: 'Voice-over',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _recording
                ? 'Recording from ${TimeUtils.formatShort(_insertAt)} on the timeline.'
                : 'The recording is placed at the playhead, on its own audio track.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.xl),

          Center(
            child: Text(
              TimeUtils.formatTimecode(_elapsed),
              style: AppTheme.timecode(context, size: 34),
            ),
          ),
          const SizedBox(height: Spacing.lg),

          _LevelMeter(level: _level, active: _recording && !_paused),

          if (_clippedAtAnyPoint) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    'Peaked near full scale — clipping cannot be undone later. '
                    'Move back from the mic and re-record.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],

          const SizedBox(height: Spacing.xxl),

          if (!_recording)
            GradientButton(
              label: 'Start recording',
              icon: Icons.mic_rounded,
              expand: true,
              busy: _busy,
              gradient: AppColors.dangerGradient,
              onPressed: _busy ? null : _start,
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _togglePause,
                    icon: Icon(
                      _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    ),
                    label: Text(_paused ? 'Resume' : 'Pause'),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  flex: 2,
                  child: GradientButton(
                    label: 'Stop & add',
                    icon: Icons.check_rounded,
                    expand: true,
                    busy: _busy,
                    onPressed: _busy ? null : _stopAndInsert,
                  ),
                ),
              ],
            ),

          const SizedBox(height: Spacing.sm),
          TextButton(
            onPressed: _busy ? null : _discard,
            child: Text(_recording ? 'Discard' : 'Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Segmented level meter. Green below −12 dB, amber approaching, red at the
/// top — the standard broadcast reading, so it needs no legend.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.active});

  final RecordingLevel? level;
  final bool active;

  static const int _segments = 28;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = active ? (level?.normalised ?? 0) : 0.0;
    final lit = (value * _segments).round();

    return Column(
      children: [
        SizedBox(
          height: 34,
          child: Row(
            children: [
              for (var i = 0; i < _segments; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: AnimatedContainer(
                      duration: Motion.instant,
                      decoration: BoxDecoration(
                        color: i < lit
                            ? _segmentColour(i)
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          active && level != null
              ? '${level!.current.toStringAsFixed(1)} dB'
              : '—',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Color _segmentColour(int index) {
    final position = index / _segments;
    if (position > 0.9) return AppColors.danger;
    if (position > 0.75) return AppColors.warning;
    return AppColors.success;
  }
}
