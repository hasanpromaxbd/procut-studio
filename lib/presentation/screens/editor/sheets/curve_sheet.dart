/// The keyframe curve editor.
///
/// Easing presets cover most of what an edit needs, but "most" is exactly the
/// gap that makes motion feel canned. This shows the actual curve between two
/// keyframes with two draggable bézier handles — the thing that turns a
/// mechanical move into one with weight.
///
/// It edits the segment *leaving* the selected keyframe, because that is what
/// a cubic bézier easing describes: how the value travels from this keyframe
/// to the next.
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/keyframe.dart';
import '../../../../domain/usecases/timeline_operations.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class CurveSheet extends ConsumerStatefulWidget {
  const CurveSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<CurveSheet> createState() => _CurveSheetState();
}

class _CurveSheetState extends ConsumerState<CurveSheet> {
  TransformChannel _channel = TransformChannel.scaleX;
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final clip = clipId == null ? null : editor!.timeline.findClip(clipId)?.$2;

    if (clip == null) {
      return ToolSheet(
        title: 'Curves',
        child: Text(
          'Select a clip with keyframes to shape its motion.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final animatedChannels = [
      for (final channel in TransformChannel.values)
        if (_channelOf(clip, channel).isAnimated) channel,
    ];
    if (animatedChannels.isNotEmpty && !animatedChannels.contains(_channel)) {
      _channel = animatedChannels.first;
    }

    final track = _channelOf(clip, _channel);
    final keys = track.keyframes;
    final segmentCount = keys.length <= 1 ? 0 : keys.length - 1;
    if (_segment >= segmentCount) _segment = segmentCount == 0 ? 0 : segmentCount - 1;

    return ToolSheet(
      title: 'Curves',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (animatedChannels.isEmpty)
            Text(
              'This clip has no keyframed motion yet. Add keyframes from the '
              'inspector, then shape them here.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            Wrap(
              spacing: Spacing.xs,
              children: [
                for (final channel in animatedChannels)
                  ChoiceChip(
                    selected: _channel == channel,
                    label: Text(channel.label),
                    onSelected: (_) => setState(() {
                      _channel = channel;
                      _segment = 0;
                    }),
                  ),
              ],
            ),

            if (segmentCount > 1) ...[
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Text('Segment', style: theme.textTheme.bodySmall),
                  const SizedBox(width: Spacing.sm),
                  for (var i = 0; i < segmentCount; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.xs),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        selected: _segment == i,
                        label: Text('${i + 1}'),
                        onSelected: (_) => setState(() => _segment = i),
                      ),
                    ),
                ],
              ),
            ],

            if (segmentCount > 0) ...[
              const SizedBox(height: Spacing.md),
              _CurveCanvas(
                from: keys[_segment],
                to: keys[_segment + 1],
                onChanged: (bezier) => _applyBezier(clip, keys, bezier),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                '${TimeUtils.formatShort(keys[_segment].time)} → '
                '${TimeUtils.formatShort(keys[_segment + 1].time)} · '
                '${keys[_segment].value.toStringAsFixed(2)} → '
                '${keys[_segment + 1].value.toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall,
              ),

              const SectionHeader(title: 'Or start from a preset'),
              Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  for (final preset in _presets.entries)
                    ActionChip(
                      label: Text(preset.key),
                      onPressed: () => _applyBezier(clip, keys, preset.value),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The four-number cubic béziers behind the named feels. Same control
  /// points CSS uses, so they behave the way people already expect.
  static const _presets = <String, List<double>>{
    'Linear': [0, 0, 1, 1],
    'Ease in': [0.42, 0, 1, 1],
    'Ease out': [0, 0, 0.58, 1],
    'Ease both': [0.42, 0, 0.58, 1],
    'Snappy': [0.2, 0, 0, 1],
    'Gentle': [0.4, 0.1, 0.2, 1],
    'Overshoot': [0.34, 1.56, 0.64, 1],
  };

  static AnimatableDouble _channelOf(Clip clip, TransformChannel channel) =>
      switch (channel) {
        TransformChannel.x => clip.transform.x,
        TransformChannel.y => clip.transform.y,
        TransformChannel.scaleX => clip.transform.scaleX,
        TransformChannel.scaleY => clip.transform.scaleY,
        TransformChannel.rotation => clip.transform.rotation,
        TransformChannel.opacity => clip.transform.opacity,
      };

  void _applyBezier(Clip clip, List<Keyframe> keys, List<double> bezier) {
    final updated = keys[_segment].copyWith(
      easing: Easing.custom,
      bezier: bezier,
    );
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .setKeyframeEasing(clip.id, _channel, updated);
    unawaited(HapticFeedback.selectionClick());
  }
}

/// The curve itself, with two draggable handles.
class _CurveCanvas extends StatefulWidget {
  const _CurveCanvas({
    required this.from,
    required this.to,
    required this.onChanged,
  });

  final Keyframe from;
  final Keyframe to;
  final ValueChanged<List<double>> onChanged;

  @override
  State<_CurveCanvas> createState() => _CurveCanvasState();
}

class _CurveCanvasState extends State<_CurveCanvas> {
  late List<double> _bezier = _initial();

  List<double> _initial() {
    final b = widget.from.bezier;
    if (widget.from.easing == Easing.custom && b != null && b.length == 4) {
      return List.of(b);
    }
    return switch (widget.from.easing) {
      Easing.linear || Easing.hold => const [0.0, 0.0, 1.0, 1.0],
      Easing.easeIn => const [0.42, 0.0, 1.0, 1.0],
      Easing.easeOut => const [0.0, 0.0, 0.58, 1.0],
      Easing.back => const [0.34, 1.56, 0.64, 1.0],
      _ => const [0.42, 0.0, 0.58, 1.0],
    };
  }

  @override
  void didUpdateWidget(_CurveCanvas old) {
    super.didUpdateWidget(old);
    if (old.from != widget.from) _bezier = _initial();
  }

  /// Which handle a drag grabbed. Chosen on touch-down by proximity and held
  /// for the whole gesture — re-deciding mid-drag makes the handles swap
  /// under the finger when the curve is steep.
  int? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1.6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) =>
                  _dragging = _nearestHandle(details.localPosition, size),
              onPanUpdate: (details) => _drag(details.localPosition, size),
              onPanEnd: (_) {
                _dragging = null;
                widget.onChanged(_bezier);
              },
              child: CustomPaint(
                painter: _CurvePainter(
                  bezier: _bezier,
                  line: theme.colorScheme.primary,
                  grid: theme.colorScheme.outlineVariant,
                  handle: theme.colorScheme.secondary,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Curve space is x right, y *up* — the opposite of screen space, which is
  /// where sign errors in this kind of editor come from.
  Offset _toScreen(double x, double y, Size size) =>
      Offset(x * size.width, size.height - y * size.height);

  int _nearestHandle(Offset point, Size size) {
    final first = _toScreen(_bezier[0], _bezier[1], size);
    final second = _toScreen(_bezier[2], _bezier[3], size);
    return (point - first).distance <= (point - second).distance ? 0 : 1;
  }

  void _drag(Offset point, Size size) {
    final handle = _dragging;
    if (handle == null) return;

    // x stays inside the segment; y may overshoot, which is what gives a
    // curve its bounce.
    final x = (point.dx / size.width).clamp(0.0, 1.0);
    final y = (1 - point.dy / size.height).clamp(-0.6, 1.6);

    setState(() {
      _bezier = List.of(_bezier);
      _bezier[handle * 2] = x;
      _bezier[handle * 2 + 1] = y;
    });
  }
}

class _CurvePainter extends CustomPainter {
  const _CurvePainter({
    required this.bezier,
    required this.line,
    required this.grid,
    required this.handle,
  });

  final List<double> bezier;
  final Color line;
  final Color grid;
  final Color handle;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y) =>
        Offset(x * size.width, size.height - y * size.height);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final t = i / 4;
      canvas
        ..drawLine(at(t, 0), at(t, 1), gridPaint)
        ..drawLine(at(0, t), at(1, t), gridPaint);
    }
    // The straight line from start to end: how far the curve departs from it
    // *is* the easing.
    canvas.drawLine(
      at(0, 0),
      at(1, 1),
      Paint()
        ..color = grid
        ..strokeWidth = 1,
    );

    final start = at(0, 0);
    final end = at(1, 1);
    final c1 = at(bezier[0], bezier[1]);
    final c2 = at(bezier[2], bezier[3]);

    canvas.drawPath(
      Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy),
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    final leash = Paint()
      ..color = handle.withValues(alpha: 0.5)
      ..strokeWidth = 1.5;
    canvas
      ..drawLine(start, c1, leash)
      ..drawLine(end, c2, leash);

    final knob = Paint()..color = handle;
    canvas
      ..drawCircle(c1, 8, knob)
      ..drawCircle(c2, 8, knob);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) =>
      old.bezier != bezier || old.line != line;
}
