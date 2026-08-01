/// Premium colour grading — the filter side.
///
/// ## The shape of a grade
///
/// A grade is not one slider. It is a small pipeline applied in a fixed order,
/// and the order is the reason it works:
///
///   1. **White balance** — a source-referred correction. Neutralising the
///      light *first* means everything after it operates on plausible colour.
///   2. **Tone** — where black, white and the mid-tones sit, and how steeply
///      the picture climbs between them.
///   3. **Three-way wheels** — a hue push into shadows, mid-tones and
///      highlights independently. This is where a look is actually made.
///   4. **Saturation** — vibrance (which protects what is already saturated)
///      before flat saturation.
///
/// Doing it in any other order fights itself: saturating before balancing
/// amplifies the cast you are about to remove.
///
/// ## One instance per filter
///
/// Every filter here appears at most once. That is a hard constraint, not a
/// style choice: runtime commands address a filter by `name@label`, and the
/// automation labels the *first* unlabelled instance of each name. Two
/// `colorbalance` instances in one effect would leave the second unaddressable
/// and it would silently freeze at its first-frame value. Where two controls
/// want the same filter, they are combined into one instance instead.
library;

import 'dart:math' as math;

import '../../domain/entities/effect.dart';
import '../ffmpeg/filter_graph.dart';

/// One zone of the three-way wheels, resolved to per-channel offsets.
class GradeWheel {
  const GradeWheel(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;

  bool get isNeutral => r.abs() < 0.002 && g.abs() < 0.002 && b.abs() < 0.002;

  /// Converts a wheel position to per-channel offsets.
  ///
  /// The wheel is the familiar one: angle is hue, distance from the centre is
  /// how far to push. Red sits at 90°, green at 210°, blue at 330°, and each
  /// channel's offset is the projection of the wheel vector onto its own axis.
  ///
  /// Because those three directions are 120° apart their projections sum to
  /// zero, so a push towards red lifts red and lowers green and blue by half
  /// as much each. That is what makes it a *hue* push rather than a brightness
  /// change — the alternative, moving one channel alone, visibly lightens the
  /// zone as it tints it.
  factory GradeWheel.fromPosition(double x, double y, {double scale = 0.5}) {
    final radius = math.min(1.0, math.sqrt(x * x + y * y));
    if (radius < 0.002) return const GradeWheel(0, 0, 0);
    final angle = math.atan2(y, x);
    double project(double axisDegrees) =>
        radius * math.cos(angle - axisDegrees * math.pi / 180) * scale;
    return GradeWheel(project(90), project(210), project(330));
  }
}

abstract final class GradeCompiler {
  /// Neutral daylight, in mireds. Warmth is applied as a shift in *this* unit
  /// rather than in Kelvin because equal mired steps look like equal steps —
  /// 3000→3500K is an obvious change, 9000→9500K is nearly invisible.
  static const _neutralMired = 1e6 / 6500;
  static const _miredPerUnit = 90.0;

  static const _minKelvin = 2500.0;
  static const _maxKelvin = 12000.0;

  static List<Filter> build(ResolvedEffect effect) {
    final mix = effect.intensity.clamp(0.0, 1.0);
    if (mix <= 0.001) return const [];

    final filters = <Filter>[];

    // ── 1. White balance ────────────────────────────────────────────────
    final warmth = effect.value('warmth').clamp(-1.0, 1.0) * mix;
    if (warmth.abs() > 0.002) {
      filters.add(
        Filter('colortemperature', {
          'temperature': FilterGraph.formatDouble(kelvinFor(warmth)),
          'mix': 1,
          // Without this a warm grade also dims the picture, because the
          // filter is scaling two of three channels down to make the third
          // dominant. Preserving lightness keeps exposure where the user left
          // it and makes the control mean only what its label says.
          'pl': 1,
        }),
      );
    }

    final tint = effect.value('tint').clamp(-1.0, 1.0) * mix;
    if (tint.abs() > 0.002) {
      // Green against magenta, the axis white balance needs and colour
      // temperature cannot express — magenta is not on the Planckian locus.
      filters.add(
        Filter('colorchannelmixer', {
          'rr': FilterGraph.formatDouble(1 - tint * 0.06),
          'gg': FilterGraph.formatDouble(1 + tint * 0.12),
          'bb': FilterGraph.formatDouble(1 - tint * 0.06),
        }),
      );
    }

    // ── 2. Tone ─────────────────────────────────────────────────────────
    final curve = tonePoints(
      contrast: effect.value('contrast').clamp(-1.0, 1.0) * mix,
      pivot: effect.value('pivot', 0.5).clamp(0.15, 0.85),
      shadows: effect.value('shadows').clamp(-1.0, 1.0) * mix,
      highlights: effect.value('highlights').clamp(-1.0, 1.0) * mix,
    );
    if (curve != null) {
      // Deliberately not pre-quoted: `escapeValue` quotes any value containing
      // spaces exactly once. Quoting here as well emits `all='\'0/0 …\''`,
      // which fails to parse and takes the whole graph down with it.
      filters.add(Filter('curves', {'all': curve}));
    }

    // ── 3. Three-way wheels ─────────────────────────────────────────────
    final lift = GradeWheel.fromPosition(
      effect.value('liftX') * mix,
      effect.value('liftY') * mix,
    );
    final gamma = GradeWheel.fromPosition(
      effect.value('gammaX') * mix,
      effect.value('gammaY') * mix,
    );
    final gain = GradeWheel.fromPosition(
      effect.value('gainX') * mix,
      effect.value('gainY') * mix,
    );
    if (!lift.isNeutral || !gamma.isNeutral || !gain.isNeutral) {
      filters.add(
        Filter('colorbalance', {
          'rs': FilterGraph.formatDouble(lift.r),
          'gs': FilterGraph.formatDouble(lift.g),
          'bs': FilterGraph.formatDouble(lift.b),
          'rm': FilterGraph.formatDouble(gamma.r),
          'gm': FilterGraph.formatDouble(gamma.g),
          'bm': FilterGraph.formatDouble(gamma.b),
          'rh': FilterGraph.formatDouble(gain.r),
          'gh': FilterGraph.formatDouble(gain.g),
          'bh': FilterGraph.formatDouble(gain.b),
          // `pl=1` is left off deliberately. Preserving lightness makes the
          // filter take back from two channels what it gives the third, so a
          // lift into warm *darkens* the other two and black stays black —
          // which is not what a lift is. Lightness belongs to the tone curve,
          // one step above; this stage only moves hue.
        }),
      );
    }

    // ── 4. Saturation ───────────────────────────────────────────────────
    final vibrance = effect.value('vibrance').clamp(-1.0, 1.0) * mix;
    if (vibrance.abs() > 0.002) {
      // Vibrance leans on what is *not* already saturated, which is why it can
      // be pushed much further than saturation before skin turns to plastic.
      filters.add(
        Filter('vibrance', {
          'intensity': FilterGraph.formatDouble(vibrance * 0.8),
        }),
      );
    }

    final saturation = 1 + (effect.value('saturation', 1) - 1) * mix;
    if ((saturation - 1).abs() > 0.002) {
      filters.add(
        Filter('hue', {'s': FilterGraph.formatDouble(saturation)}),
      );
    }

    return filters;
  }

  /// Colour temperature for a warmth position, positive being warmer.
  ///
  /// Note the inversion: a *warm* picture is what a low-Kelvin lamp produces,
  /// so pushing the control right lowers the number. The control is labelled
  /// "warmth" rather than "temperature" for exactly that reason — a slider
  /// that says 3200K and looks orange confuses everyone once.
  static double kelvinFor(double warmth) {
    final mired = _neutralMired + warmth * _miredPerUnit;
    return (1e6 / mired).clamp(_minKelvin, _maxKelvin);
  }

  /// How much each wheel reaches a pixel of lightness [l], as
  /// `(shadows, midtones, highlights)`.
  ///
  /// These are not invented: they are fitted to `colorbalance`'s measured
  /// response, sampled across a full ramp (see `tool/verify_grade.sh`, which
  /// re-measures it so the fit cannot silently rot when FFmpeg changes). The
  /// preview shader implements the same three lines, which is what keeps a
  /// wheel push looking the same while scrubbing as it does on export.
  ///
  /// Two things about them are worth knowing, because they are surprising and
  /// they are the filter's, not ours: the zones meet at a lightness of 0.25,
  /// not 0.5, and the three always sum to 1.
  static (double, double, double) zoneWeights(double l) {
    final shadows = ((0.25 - l) / 0.15).clamp(0.0, 1.0);
    final highlights = ((l - 0.25) / 0.15).clamp(0.0, 1.0);
    return (shadows, (1 - shadows - highlights).clamp(0.0, 1.0), highlights);
  }

  /// The internal scale `colorbalance` applies to every offset.
  static const zoneScale = 0.7;

  /// The tone curve as `curves` points, or null when it is the identity.
  ///
  /// Five points, evenly spaced. More would let the spline wander between
  /// them; fewer cannot express a shoulder and a toe at once.
  static String? tonePoints({
    required double contrast,
    required double pivot,
    required double shadows,
    required double highlights,
  }) {
    if (contrast.abs() < 0.002 &&
        shadows.abs() < 0.002 &&
        highlights.abs() < 0.002) {
      return null;
    }

    final points = <String>[];
    var moved = false;
    for (var i = 0; i <= 4; i++) {
      final x = i / 4;
      final y = toneValue(
        x,
        contrast: contrast,
        pivot: pivot,
        shadows: shadows,
        highlights: highlights,
      );
      if ((y - x).abs() > 0.002) moved = true;
      points.add(
        '${FilterGraph.formatDouble(x)}/${FilterGraph.formatDouble(y)}',
      );
    }
    return moved ? points.join(' ') : null;
  }

  /// The tone curve evaluated at one input level, 0..1.
  ///
  /// Public because the preview shader is generated from the same numbers, and
  /// a test compares the two: a grade that looks one way while scrubbing and
  /// another way on export is the failure this whole feature has to avoid.
  static double toneValue(
    double x, {
    required double contrast,
    required double pivot,
    required double shadows,
    required double highlights,
  }) {
    var y = x;

    if (contrast.abs() > 0.002) {
      // An S built from smoothstep, which is fixed at 0 and 1 — so contrast
      // never clips a highlight that was not already clipped. The pivot is
      // applied as a power remap either side of the call, which moves the
      // inflection without moving the endpoints.
      final exponent = math.log(0.5) / math.log(pivot);
      final u = math.pow(x.clamp(0.0, 1.0), exponent).toDouble();
      final s = u * u * (3 - 2 * u);
      final shaped = math.pow(s, 1 / exponent).toDouble();
      y += contrast * (shaped - x);
    }

    if (shadows.abs() > 0.002) {
      final weight = math.max(0.0, 1 - x / 0.6);
      y += shadows * 0.22 * weight * weight;
    }
    if (highlights.abs() > 0.002) {
      final weight = math.max(0.0, (x - 0.4) / 0.6);
      y += highlights * 0.22 * weight * weight;
    }

    return y.clamp(0.0, 1.0);
  }
}
