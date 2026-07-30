/// Composition guides drawn over the preview.
///
/// Guides are view-state, not project-state: they never export, never save,
/// and turning one on is not an edit — so they live in their own provider,
/// not in the timeline.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum GuideKind {
  safeZones(
    'Safe zones',
    'Title (90%) and action (95%) margins. Keep text inside the inner box.',
  ),
  thirds('Thirds', 'The grid most framing decisions actually use.'),
  goldenRatio('Golden ratio', 'Thirds, but weighted the way paintings are.'),
  centre('Centre', 'A crosshair for symmetric framing and matched cuts.'),
  socialUi(
    'Social overlay',
    'Where a vertical platform draws its own buttons and captions over you.',
  );

  const GuideKind(this.label, this.blurb);
  final String label;
  final String blurb;
}

class GuidesState {
  const GuidesState({this.enabled = const {}});

  final Set<GuideKind> enabled;

  bool isOn(GuideKind kind) => enabled.contains(kind);
  bool get anyOn => enabled.isNotEmpty;
}

final guidesProvider = NotifierProvider<GuidesController, GuidesState>(
  GuidesController.new,
);

class GuidesController extends Notifier<GuidesState> {
  @override
  GuidesState build() => const GuidesState();

  void toggle(GuideKind kind) {
    final next = Set<GuideKind>.of(state.enabled);
    if (!next.remove(kind)) next.add(kind);
    state = GuidesState(enabled: next);
  }

  void clear() => state = const GuidesState();
}

/// Stacked over the preview stage, ignoring pointer events entirely — a guide
/// that intercepts a tap meant for the eyedropper would be worse than none.
class GuidesOverlay extends ConsumerWidget {
  const GuidesOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guides = ref.watch(guidesProvider);
    if (!guides.anyOn) return const SizedBox.shrink();

    return IgnorePointer(
      child: CustomPaint(
        painter: _GuidesPainter(enabled: guides.enabled),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GuidesPainter extends CustomPainter {
  const _GuidesPainter({required this.enabled});

  final Set<GuideKind> enabled;

  // A dark halo under a light line keeps guides visible on any footage;
  // a plain white line vanishes over sky.
  static final Paint _halo = Paint()
    ..color = Colors.black38
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;
  static final Paint _line = Paint()
    ..color = Colors.white70
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    if (enabled.contains(GuideKind.safeZones)) _safeZones(canvas, size);
    if (enabled.contains(GuideKind.thirds)) {
      _grid(canvas, size, const [1 / 3, 2 / 3]);
    }
    if (enabled.contains(GuideKind.goldenRatio)) {
      _grid(canvas, size, const [0.382, 0.618]);
    }
    if (enabled.contains(GuideKind.centre)) _centre(canvas, size);
    if (enabled.contains(GuideKind.socialUi)) _socialUi(canvas, size);
  }

  void _stroke(Canvas canvas, Path path) {
    canvas.drawPath(path, _halo);
    canvas.drawPath(path, _line);
  }

  void _safeZones(Canvas canvas, Size size) {
    for (final fraction in const [0.95, 0.90]) {
      final rect = Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * fraction,
        height: size.height * fraction,
      );
      _stroke(canvas, Path()..addRect(rect));
    }
  }

  void _grid(Canvas canvas, Size size, List<double> stops) {
    final path = Path();
    for (final stop in stops) {
      path
        ..moveTo(size.width * stop, 0)
        ..lineTo(size.width * stop, size.height)
        ..moveTo(0, size.height * stop)
        ..lineTo(size.width, size.height * stop);
    }
    _stroke(canvas, path);
  }

  void _centre(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final arm = size.shortestSide * 0.06;
    _stroke(
      canvas,
      Path()
        ..moveTo(c.dx - arm, c.dy)
        ..lineTo(c.dx + arm, c.dy)
        ..moveTo(c.dx, c.dy - arm)
        ..lineTo(c.dx, c.dy + arm),
    );
  }

  /// The regions a vertical platform covers with its own UI: a caption band
  /// along the bottom and an action rail down the right edge. Shaded, not
  /// outlined — the point is "do not put anything important here".
  void _socialUi(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black26;
    // Bottom ~18%: caption, username, sounds.
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.82, size.width, size.height * 0.18),
      shade,
    );
    // Right ~14%, lower two thirds: like/comment/share rail.
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.86,
        size.height * 0.30,
        size.width * 0.14,
        size.height * 0.52,
      ),
      shade,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidesPainter old) =>
      !setEquals(old.enabled, enabled);
}
