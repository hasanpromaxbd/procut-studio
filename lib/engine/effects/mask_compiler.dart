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

import '../../domain/entities/keyframe.dart';
import '../../domain/entities/mask.dart';
import '../ffmpeg/filter_graph.dart';

abstract final class MaskCompiler {
  /// Filters that apply an animated [mask] over a clip of [duration].
  ///
  /// A static mask compiles to the same constant expression as before. An
  /// animated one has its moving parameters written as expressions in `T`,
  /// FFmpeg's frame timestamp in seconds — `geq` accepts no runtime commands,
  /// so `sendcmd` is not an option and the animation has to live in the
  /// expression itself.
  static List<Filter> buildAnimated(Mask mask, Duration duration) {
    if (!mask.isActive) return const [];
    if (!mask.isAnimated) return build(mask.resolveAt(Duration.zero));

    return [
      Filter('format', {'pix_fmts': 'yuva420p'}),
      Filter('geq', {
        'lum': 'p(X,Y)',
        'cb': 'p(X,Y)',
        'cr': 'p(X,Y)',
        'a': _animatedAlphaExpression(mask, duration),
      }),
    ];
  }

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

  /// The same alpha expression as [_alphaExpression], with every animated
  /// parameter replaced by a term in `T`.
  ///
  /// Deliberately parallel to the static version rather than a generalisation
  /// of it: the static path runs on every pixel of every frame of every masked
  /// clip, and making it carry unused interpolation would be a real cost for
  /// the common case.
  static String _animatedAlphaExpression(Mask mask, Duration duration) {
    final f = FilterGraph.formatDouble;

    String channel(AnimatableDouble value) => _timeExpression(value, f);

    const aspect = '(W/H)';
    final dx = '((X/W-${channel(mask.centerX)})*$aspect)';
    final dy = '(Y/H-${channel(mask.centerY)})';

    // Rotation is baked per frame the same way, but as an expression the
    // evaluator computes once per pixel — acceptable, and the alternative
    // (pre-rotating the frame) would move the picture, not the mask.
    final rot = '(${channel(mask.rotation)}*0.017453292519943295)';
    final rx = '($dx*cos($rot)+$dy*sin($rot))';
    final ry = '(-$dx*sin($rot)+$dy*cos($rot))';

    final halfW = 'max(abs(${channel(mask.width)}),0.0001)';
    final halfH = 'max(abs(${channel(mask.height)}),0.0001)';

    final dist = switch (mask.shape) {
      MaskShape.rectangle =>
        'max(abs($rx)/(($halfW)*$aspect),abs($ry)/($halfH))',
      MaskShape.ellipse =>
        'sqrt(pow($rx/(($halfW)*$aspect),2)+pow($ry/($halfH),2))',
      MaskShape.linear => '($ry/($halfH)*0.5+0.5)',
      MaskShape.none => '0',
    };

    final feather = 'max(abs(${channel(mask.feather)})/($halfH),0.0001)';
    final alpha = 'clip((1+$feather-($dist))/(2*$feather),0,1)';
    return mask.inverted ? '255*(1-($alpha))' : '255*($alpha)';
  }

  /// A channel as an FFmpeg expression in `T`.
  ///
  /// Constant channels collapse to a literal. An animated one becomes nested
  /// `if`s — one segment per keyframe pair, linear inside each. Linear rather
  /// than the keyframe's own easing curve: the evaluator has no smoothstep,
  /// and at the segment counts a hand-built mask animation actually uses, the
  /// difference is imperceptible. The doc comment on [Mask] says as much.
  static String _timeExpression(
    AnimatableDouble channel,
    String Function(double) f,
  ) {
    if (!channel.isAnimated) return f(channel.valueAt(Duration.zero));

    final keys = channel.keyframes;
    var expression = f(keys.last.value);

    // Built from the last segment backwards, so each `if` only has to decide
    // "is T before this keyframe" and can defer to what it wraps.
    for (var i = keys.length - 1; i >= 1; i--) {
      final a = keys[i - 1];
      final b = keys[i];
      final t0 = a.time.inMicroseconds / 1e6;
      final t1 = b.time.inMicroseconds / 1e6;
      final span = (t1 - t0).abs() < 1e-6 ? 1e-6 : t1 - t0;

      final lerp =
          '${f(a.value)}+${f(b.value - a.value)}*'
          '(clip((T-${f(t0)})/${f(span)},0,1))';
      expression = 'if(lt(T,${f(t1)}),$lerp,$expression)';
    }

    // Before the first keyframe the value is held, matching how
    // `AnimatableDouble.valueAt` clamps rather than extrapolates.
    return '(if(lt(T,${f(keys.first.time.inMicroseconds / 1e6)}),'
        '${f(keys.first.value)},$expression))';
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
