/// Compiles a [Mask] into FFmpeg filters, matching `shaders/mask.frag`.
///
/// The alpha channel is written directly with `geq`, which evaluates an
/// expression per pixel and can address the alpha plane as `a=`. That avoids
/// generating a separate mask video and merging it — one filter, no extra
/// input, no second decode.
///
/// The expression is a transliteration of the shader, deliberately: the same
/// normalised distance metric, the same feather. If one changes the other must,
/// and a test asserts they agree at sampled points.
library;

import '../../domain/entities/mask.dart';
import '../ffmpeg/filter_graph.dart';

abstract final class MaskCompiler {
  /// Filters that apply [mask] to the current stream. Empty when inactive.
  static List<Filter> build(ResolvedMask mask) {
    if (!mask.isActive) return const [];

    final expression = _alphaExpression(mask);

    return [
      // An alpha plane has to exist before it can be written to.
      Filter('format', {'pix_fmts': 'yuva420p'}),
      Filter('geq', {
        // Luma and chroma pass through untouched; only alpha is computed.
        'lum': 'p(X,Y)',
        'cb': 'p(X,Y)',
        'cr': 'p(X,Y)',
        'a': expression,
      }),
    ];
  }

  /// Builds the per-pixel alpha expression.
  ///
  /// FFmpeg's expression evaluator has no `smoothstep`, so the shader's
  /// smoothstep is replaced by a clamped linear ramp. Across a feather of a few
  /// percent of the canvas the difference is invisible, and a linear ramp is
  /// far cheaper per pixel.
  static String _alphaExpression(ResolvedMask mask) {
    final f = FilterGraph.formatDouble;

    // Canvas-normalised, aspect-corrected — identical to the shader.
    const aspect = '(W/H)';
    final dx = '((X/W-${f(mask.centerX)})*$aspect)';
    final dy = '(Y/H-${f(mask.centerY)})';

    final radians = mask.rotation * 3.14159265358979 / 180.0;
    final cos = f(_cos(radians));
    final sin = f(_sin(radians));

    final rx = '($dx*$cos+$dy*$sin)';
    final ry = '(-$dx*$sin+$dy*$cos)';

    final halfW = f(_atLeast(mask.width * 1.0, 1e-4));
    final halfH = f(_atLeast(mask.height, 1e-4));

    final dist = switch (mask.shape) {
      // Chebyshev in normalised half-extents.
      MaskShape.rectangle =>
        'max(abs($rx)/($halfW*$aspect),abs($ry)/$halfH)',
      // Euclidean in the same space.
      MaskShape.ellipse =>
        'sqrt(pow($rx/($halfW*$aspect),2)+pow($ry/$halfH,2))',
      // Signed half-plane.
      MaskShape.linear => '($ry/$halfH*0.5+0.5)',
      MaskShape.none => '0',
    };

    final feather = f(_atLeast(mask.feather / _atLeast(mask.height, 1e-4), 1e-4));

    // 1 at the centre, 0 beyond the feathered edge.
    final alpha = 'clip((1+$feather-($dist))/(2*$feather),0,1)';

    return mask.inverted ? '255*(1-($alpha))' : '255*($alpha)';
  }

  static double _atLeast(double value, double floor) =>
      value.abs() < floor ? floor : value.abs();

  // Small local trig so the expression carries constants rather than asking
  // FFmpeg to evaluate cos/sin per pixel for a value fixed across the frame.
  static double _cos(double radians) => _taylorCos(radians);
  static double _sin(double radians) => _taylorCos(radians - 1.5707963267948966);

  static double _taylorCos(double x) {
    // Normalise into [-π, π] first, or the series diverges for large angles.
    const twoPi = 6.283185307179586;
    var t = x % twoPi;
    if (t > 3.141592653589793) t -= twoPi;
    if (t < -3.141592653589793) t += twoPi;

    final x2 = t * t;
    return 1 -
        x2 / 2 +
        x2 * x2 / 24 -
        x2 * x2 * x2 / 720 +
        x2 * x2 * x2 * x2 / 40320;
  }
}
