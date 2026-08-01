/// Maps the ten transition types onto FFmpeg's `xfade` and onto preview
/// shaders.
///
/// Six of them have exact native `xfade` equivalents. The other four (spin,
/// warp, ripple, glitch) do not exist natively, so each ships two
/// implementations:
///
///  * **exact** — `xfade=transition=custom` with a per-pixel expression. This
///    looks right but FFmpeg evaluates the expression once per pixel per plane
///    per frame, which is roughly 10–30× slower than a native transition.
///  * **fast** — the closest native transition.
///
/// [TransitionCatalog.resolve] picks between them, and the export screen
/// exposes the choice rather than silently making it. Getting a plausible
/// result in 40 seconds is usually worth more than a perfect one in 6 minutes,
/// but that is the user's call to make.
library;

import 'package:flutter/material.dart' hide Easing;

import '../../domain/entities/keyframe.dart';
import '../../domain/entities/transition.dart';
import '../ffmpeg/filter_graph.dart';

@immutable
class TransitionSpec {
  const TransitionSpec({
    required this.type,
    required this.label,
    required this.icon,
    required this.nativeName,
    this.shaderAsset,
    this.customExpression,
    this.directionalNames = const {},
  });

  final TransitionType type;
  final String label;
  final IconData icon;

  /// The `xfade` transition used directly, or the fast approximation when
  /// [customExpression] is set.
  final String nativeName;

  final String? shaderAsset;

  /// Per-pixel expression for `xfade=transition=custom:expr=…`.
  /// Null when the native transition is already exact.
  final String Function(Transition transition)? customExpression;

  /// Native names per direction for the directional transitions.
  final Map<TransitionDirection, String> directionalNames;

  bool get isExactNatively => customExpression == null;

  String nativeFor(TransitionDirection direction) =>
      directionalNames[direction] ?? nativeName;
}

abstract final class TransitionCatalog {
  static final Map<TransitionType, TransitionSpec> _specs = {
    for (final spec in all) spec.type: spec,
  };

  static TransitionSpec? specFor(TransitionType type) => _specs[type];

  static final List<TransitionSpec> all = [
    const TransitionSpec(
      type: TransitionType.fade,
      label: 'Fade',
      icon: Icons.gradient_rounded,
      nativeName: 'fade',
      shaderAsset: 'shaders/transition_fade.frag',
    ),

    const TransitionSpec(
      type: TransitionType.zoom,
      label: 'Zoom',
      icon: Icons.zoom_out_map_rounded,
      nativeName: 'zoomin',
      shaderAsset: 'shaders/transition_warp.frag',
    ),

    const TransitionSpec(
      type: TransitionType.slide,
      label: 'Slide',
      icon: Icons.swipe_left_rounded,
      nativeName: 'slideleft',
      shaderAsset: 'shaders/transition_fade.frag',
      directionalNames: {
        TransitionDirection.left: 'slideleft',
        TransitionDirection.right: 'slideright',
        TransitionDirection.up: 'slideup',
        TransitionDirection.down: 'slidedown',
      },
    ),

    const TransitionSpec(
      type: TransitionType.push,
      label: 'Push',
      icon: Icons.east_rounded,
      nativeName: 'wipeleft',
      shaderAsset: 'shaders/transition_fade.frag',
      directionalNames: {
        TransitionDirection.left: 'wipeleft',
        TransitionDirection.right: 'wiperight',
        TransitionDirection.up: 'wipeup',
        TransitionDirection.down: 'wipedown',
      },
    ),

    const TransitionSpec(
      type: TransitionType.flash,
      label: 'Flash',
      icon: Icons.flash_on_rounded,
      nativeName: 'fadewhite',
      shaderAsset: 'shaders/transition_fade.frag',
    ),

    const TransitionSpec(
      type: TransitionType.blur,
      label: 'Blur',
      icon: Icons.blur_circular_rounded,
      nativeName: 'hblur',
      shaderAsset: 'shaders/transition_fade.frag',
    ),

    // ── Non-native: exact via custom expression ────────────────────────

    TransitionSpec(
      type: TransitionType.spin,
      label: 'Spin',
      icon: Icons.rotate_right_rounded,
      nativeName: 'circleopen', // fast approximation
      shaderAsset: 'shaders/transition_warp.frag',
      customExpression: (t) {
        // Rotate the outgoing frame about the centre while it fades out.
        // Angle sweeps 0 → 2π·intensity across the transition.
        final turns = FilterGraph.formatDouble(t.intensity * 6.2831853);
        return _sampleRotated(turns);
      },
    ),

    TransitionSpec(
      type: TransitionType.warp,
      label: 'Warp',
      icon: Icons.waves_rounded,
      nativeName: 'squeezeh',
      shaderAsset: 'shaders/transition_warp.frag',
      customExpression: (t) {
        // Horizontal pinch that peaks mid-transition, then releases.
        final strength = FilterGraph.formatDouble(t.intensity * 0.45);
        return _sampleWarped(strength);
      },
    ),

    TransitionSpec(
      type: TransitionType.ripple,
      label: 'Ripple',
      icon: Icons.water_rounded,
      nativeName: 'radial',
      shaderAsset: 'shaders/transition_ripple.frag',
      customExpression: (t) {
        final amplitude = FilterGraph.formatDouble(t.intensity * 24);
        return _sampleRippled(amplitude);
      },
    ),

    TransitionSpec(
      type: TransitionType.glitch,
      label: 'Glitch',
      icon: Icons.broken_image_rounded,
      nativeName: 'pixelize',
      shaderAsset: 'shaders/transition_glitch.frag',
      customExpression: (t) {
        final shift = FilterGraph.formatDouble(t.intensity * 60);
        return _sampleGlitched(shift);
      },
    ),
  ];

  /// Builds the `xfade` filter for [transition] starting at [offset].
  ///
  /// [offset] is the time within the *combined* stream at which the overlap
  /// begins — `xfade` measures from the start of its first input, not from the
  /// timeline origin, which is the single easiest thing to get wrong here.
  static Filter buildXfade(
    Transition transition,
    Duration offset, {
    bool preferFastApproximation = false,
  }) {
    final spec = _specs[transition.type];
    final durationSeconds = transition.duration.inMicroseconds / 1e6;
    final offsetSeconds = offset.inMicroseconds / 1e6;

    if (spec == null) {
      return Filter('xfade', {
        'transition': 'fade',
        'duration': FilterGraph.formatDouble(durationSeconds),
        'offset': FilterGraph.formatDouble(offsetSeconds),
      });
    }

    final useCustom =
        spec.customExpression != null && !preferFastApproximation;

    if (useCustom) {
      return Filter('xfade', {
        'transition': 'custom',
        'expr': _eased(spec.customExpression!(transition), transition.easing),
        'duration': FilterGraph.formatDouble(durationSeconds),
        'offset': FilterGraph.formatDouble(offsetSeconds),
      });
    }

    return Filter('xfade', {
      'transition': spec.nativeFor(transition.direction),
      'duration': FilterGraph.formatDouble(durationSeconds),
      'offset': FilterGraph.formatDouble(offsetSeconds),
    });
  }

  /// Whether [type] can honour an easing curve at all.
  ///
  /// Only the expression-based transitions can: they compute progress
  /// themselves, so the curve can be substituted in. `xfade`'s built-in
  /// transitions advance linearly inside FFmpeg and expose no way to change
  /// that, so offering the control for them would be a lie.
  static bool supportsEasing(TransitionType type) =>
      _specs[type]?.customExpression != null;

  /// Rewrites a custom expression to advance on an eased curve.
  ///
  /// The expression's progress variable is `P`, 0 at the start of the
  /// transition and 1 at its end. Substituting an eased function of `P` for
  /// every occurrence bends the whole transition without the expression
  /// builders needing to know about easing at all.
  static String _eased(String expression, Easing easing) {
    final curve = _progressExpression(easing);
    if (curve == 'P') return expression;
    // Single-letter variables (X, Y, W, H, P, A, B), so a word boundary is an
    // exact match — nothing else in these expressions is a bare `P`.
    return expression.replaceAll(RegExp(r'\bP\b'), '($curve)');
  }

  static String _progressExpression(Easing easing) => switch (easing) {
    Easing.linear => 'P',
    // A transition that holds is a cut with extra steps; there is nothing
    // sensible to hold *at*, so it advances linearly.
    Easing.hold => 'P',
    Easing.easeIn => '(P*P)',
    Easing.easeOut => '(1-(1-P)*(1-P))',
    Easing.easeInOut => '(P*P*(3-2*P))',
    // The standard back-ease overshoot constant.
    Easing.back => '(P*P*(2.70158*P-1.70158))',
    // A cubic bézier's y at a given x has no closed form, and solving it per
    // pixel is not an option. Smoothstep is the closest fixed curve, and the
    // sheet says a custom curve falls back to it.
    Easing.custom => '(P*P*(3-2*P))',
  };

  /// True when rendering [transition] exactly will be materially slow.
  static bool isExpensive(Transition transition) =>
      _specs[transition.type]?.isExactNatively == false;

  // ── Custom expression builders ───────────────────────────────────────
  //
  // `xfade` custom expressions run over: X, Y (pixel), W, H (size), P
  // (progress 0..1), PLANE, and the samplers a0..a3 / b0..b3. Everything below
  // computes a source coordinate then samples the right plane for it.

  /// Wraps a coordinate expression so it samples the correct plane of the
  /// outgoing (`a`) frame, cross-dissolving into the incoming (`b`) frame.
  static String _planeSelect(String xExpr, String yExpr) =>
      'if(eq(PLANE,0),'
      'a0($xExpr,$yExpr)*(1-P)+b0(X,Y)*P,'
      'if(eq(PLANE,1),'
      'a1($xExpr,$yExpr)*(1-P)+b1(X,Y)*P,'
      'if(eq(PLANE,2),'
      'a2($xExpr,$yExpr)*(1-P)+b2(X,Y)*P,'
      'a3($xExpr,$yExpr)*(1-P)+b3(X,Y)*P)))';

  static String _sampleRotated(String turns) {
    // Rotation about the centre by P·turns radians.
    const cx = '(W/2)';
    const cy = '(H/2)';
    final angle = '(P*$turns)';
    final dx = '(X-$cx)';
    final dy = '(Y-$cy)';
    final sx = 'clip($cx+$dx*cos($angle)-$dy*sin($angle),0,W-1)';
    final sy = 'clip($cy+$dx*sin($angle)+$dy*cos($angle),0,H-1)';
    return _planeSelect(sx, sy);
  }

  static String _sampleWarped(String strength) {
    // Pinch strongest at P=0.5 (sin(P·π) peaks there), released at both ends.
    final k = '($strength*sin(P*PI))';
    const cx = '(W/2)';
    final sx = 'clip($cx+(X-$cx)*(1+$k),0,W-1)';
    return _planeSelect(sx, 'Y');
  }

  static String _sampleRippled(String amplitude) {
    final amp = '($amplitude*sin(P*PI))';
    final sx = 'clip(X+$amp*sin((Y/H)*20+P*12),0,W-1)';
    final sy = 'clip(Y+$amp*sin((X/W)*20+P*12),0,H-1)';
    return _planeSelect(sx, sy);
  }

  static String _sampleGlitched(String shift) {
    // Displace horizontal bands by a pseudo-random amount that changes with
    // the band index. `floor(Y/24)` gives ~24px tall tear bands.
    final magnitude = '($shift*sin(P*PI))';
    final band = '(floor(Y/24))';
    final jitter = '(sin($band*12.9898)*43758.5453)';
    final offset = '($magnitude*(2*(($jitter)-floor($jitter))-1))';
    final sx = 'clip(X+$offset,0,W-1)';
    return _planeSelect(sx, 'Y');
  }

  const TransitionCatalog._();
}
