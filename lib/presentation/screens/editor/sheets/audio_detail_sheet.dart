/// A zoomable waveform for frame-accurate audio work.
///
/// The timeline's waveform is drawn at whatever zoom the whole edit is at,
/// which is right for arranging and useless for finding the exact frame a
/// plosive starts. This shows one clip's audio at its own zoom, with the
/// playhead in clip-local time and frame-by-frame nudges.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class AudioDetailSheet extends ConsumerStatefulWidget {
  const AudioDetailSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<AudioDetailSheet> createState() => _AudioDetailSheetState();
}

class _AudioDetailSheetState extends ConsumerState<AudioDetailSheet> {
  Float32List? _peaks;
  String? _loadedAssetId;

  /// How much of the clip fills the view, 1 = all of it.
  double _zoom = 1;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final playhead = ref.watch(playheadControllerProvider);
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final clip = clipId == null ? null : editor!.timeline.findClip(clipId)?.$2;

    if (clip is! MediaClip || clip is ImageClip) {
      return ToolSheet(
        title: 'Audio detail',
        child: Text(
          'Select a clip with sound to inspect its waveform.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (_loadedAssetId != clip.assetId) {
      _loadedAssetId = clip.assetId;
      unawaited(_load(clip.assetId));
    }

    final local = playhead.position - clip.start;
    final fps = editor!.timeline.fps;

    return ToolSheet(
      title: 'Audio detail',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clip.label ?? 'Clip audio',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.sm),

          SizedBox(
            height: 132,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
              ),
              child: _peaks == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // Tap the waveform to put the playhead there — the
                        // whole reason to look at audio this closely.
                        onTapDown: (details) => _seekTo(
                          details.localPosition.dx / constraints.maxWidth,
                          clip,
                        ),
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, 132),
                          painter: _DetailPainter(
                            peaks: _peaks!,
                            clip: clip,
                            zoom: _zoom,
                            playheadFraction: clip.duration <= Duration.zero
                                ? 0
                                : local.inMicroseconds /
                                      clip.duration.inMicroseconds,
                            wave: AppColors.waveform,
                            grid: theme.colorScheme.outlineVariant,
                            cursor: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
            ),
          ),

          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              const Icon(Icons.zoom_out_rounded, size: 18),
              Expanded(
                child: Slider(
                  value: _zoom,
                  min: 1,
                  max: 40,
                  onChanged: (value) => setState(() => _zoom = value),
                ),
              ),
              const Icon(Icons.zoom_in_rounded, size: 18),
              SizedBox(
                width: 46,
                child: Text(
                  '${_zoom.round()}×',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),

          const SectionHeader(title: 'Nudge the playhead'),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final frames in [-10, -1, 1, 10])
                FilledButton.tonal(
                  onPressed: () {
                    ref
                        .read(playheadControllerProvider.notifier)
                        .stepFrames(frames);
                    unawaited(HapticFeedback.selectionClick());
                  },
                  child: Text('${frames > 0 ? '+' : ''}$frames'),
                ),
            ],
          ),

          const SizedBox(height: Spacing.sm),
          Text(
            'Playhead at ${TimeUtils.formatSmpte(
              local < Duration.zero ? Duration.zero : local,
              fps,
            )} into this clip',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Split here, then trim — the timeline tools all work while this '
            'is open.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _load(String assetId) async {
    final editor = ref.read(editorControllerProvider(widget.projectId));
    final asset = editor?.project.asset(assetId);
    if (asset == null) return;

    final result = await ref.read(mediaRepositoryProvider).waveform(asset);
    final peaks = result.valueOrNull;
    if (peaks != null && mounted) setState(() => _peaks = peaks);
  }

  void _seekTo(double fraction, MediaClip clip) {
    // The view shows a window of the clip centred on the playhead when zoomed,
    // so a tap maps through that window rather than the whole clip.
    final playhead = ref.read(playheadControllerProvider).position;
    final local = playhead - clip.start;
    final visible = Duration(
      microseconds: (clip.duration.inMicroseconds / _zoom).round(),
    );
    final windowStart = _windowStart(local, visible, clip.duration);

    final target =
        clip.start +
        windowStart +
        Duration(
          microseconds: (visible.inMicroseconds * fraction.clamp(0, 1)).round(),
        );
    ref.read(playheadControllerProvider.notifier).seek(target);
  }

  static Duration _windowStart(
    Duration local,
    Duration visible,
    Duration total,
  ) {
    final half = Duration(microseconds: visible.inMicroseconds ~/ 2);
    var start = local - half;
    if (start < Duration.zero) start = Duration.zero;
    if (start + visible > total) {
      start = total - visible;
      if (start < Duration.zero) start = Duration.zero;
    }
    return start;
  }
}

class _DetailPainter extends CustomPainter {
  const _DetailPainter({
    required this.peaks,
    required this.clip,
    required this.zoom,
    required this.playheadFraction,
    required this.wave,
    required this.grid,
    required this.cursor,
  });

  final Float32List peaks;
  final MediaClip clip;
  final double zoom;
  final double playheadFraction;
  final Color wave;
  final Color grid;
  final Color cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.height / 2;
    final half = size.height * 0.44;

    canvas.drawLine(
      Offset(0, centre),
      Offset(size.width, centre),
      Paint()
        ..color = grid
        ..strokeWidth = 1,
    );

    if (clip.duration <= Duration.zero) return;

    // Which slice of the clip is on screen, centred on the playhead.
    final visibleUs = clip.duration.inMicroseconds / zoom;
    var startUs =
        playheadFraction * clip.duration.inMicroseconds - visibleUs / 2;
    startUs = startUs.clamp(
      0.0,
      math.max(0.0, clip.duration.inMicroseconds - visibleUs),
    );

    final paint = Paint()
      ..color = wave
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    const sps = AppConstants.waveformSamplesPerSecond;
    for (var x = 0.0; x < size.width; x += 1.5) {
      final withinUs = startUs + visibleUs * (x / size.width);
      // Source time, so a trimmed or sped-up clip reads its own audio.
      final sourceUs =
          clip.sourceIn.inMicroseconds +
          (clip.reversed
              ? clip.sourceDuration.inMicroseconds - withinUs * clip.speed
              : withinUs * clip.speed);
      final index = (sourceUs / 1e6 * sps).round();
      if (index < 0 || index >= peaks.length) continue;

      final amplitude = peaks[index] * half;
      canvas.drawLine(
        Offset(x, centre - amplitude),
        Offset(x, centre + amplitude),
        paint,
      );
    }

    // The playhead sits centred whenever the window could be centred on it;
    // at the clip's edges the window stops and the cursor moves instead.
    final cursorUs = playheadFraction * clip.duration.inMicroseconds;
    final cursorX = ((cursorUs - startUs) / visibleUs) * size.width;
    if (cursorX >= 0 && cursorX <= size.width) {
      canvas.drawLine(
        Offset(cursorX, 0),
        Offset(cursorX, size.height),
        Paint()
          ..color = cursor
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DetailPainter old) =>
      old.playheadFraction != playheadFraction ||
      old.zoom != zoom ||
      old.peaks != peaks ||
      old.clip != clip;
}
