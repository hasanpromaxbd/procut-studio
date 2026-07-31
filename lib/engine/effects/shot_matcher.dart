/// Works out what to change to make one shot look like another.
///
/// Pure arithmetic over two frames' `signalstats` readings: the measuring is
/// FFmpeg's job, the judgement is here, and keeping them apart is what makes
/// the judgement testable without a video file.
///
/// ## What it can and cannot do
///
/// It matches *level and cast* — exposure, contrast, saturation, white
/// balance. That is the bulk of what makes two cameras look like two cameras.
/// It does not match a look: a shot graded teal-and-orange will not impose its
/// grade on another, because the four numbers below cannot express one. The
/// UI says "match exposure and colour", not "match the look", for that reason.
library;

import 'dart:math' as math;

/// Frame statistics, as `signalstats` reports them.
class FrameStats {
  const FrameStats({
    required this.yAverage,
    required this.yLow,
    required this.yHigh,
    required this.uAverage,
    required this.vAverage,
    required this.saturation,
  });

  /// Mean luma, 0–255.
  final double yAverage;

  /// Luma at the low and high ends of the frame's range.
  final double yLow;
  final double yHigh;

  /// Mean chroma. 128 is neutral; above on U is blue, above on V is red.
  final double uAverage;
  final double vAverage;

  final double saturation;

  double get range => (yHigh - yLow).clamp(1.0, 255.0);

  /// Parses `signalstats` output, which is the format `metadata=print`
  /// writes to the log.
  static FrameStats? fromSignalStats(Map<String, double> stats) {
    final y = stats['YAVG'];
    if (y == null) return null;
    return FrameStats(
      yAverage: y,
      yLow: stats['YLOW'] ?? 16,
      yHigh: stats['YHIGH'] ?? 235,
      uAverage: stats['UAVG'] ?? 128,
      vAverage: stats['VAVG'] ?? 128,
      saturation: stats['SATAVG'] ?? 60,
    );
  }
}

/// A proposed correction, in the same units the colour-adjust effect uses.
class ShotMatch {
  const ShotMatch({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.temperature,
  });

  final double brightness;
  final double contrast;
  final double saturation;
  final double temperature;

  /// True when the two shots already agree closely enough that applying this
  /// would be pure placebo.
  bool get isNegligible =>
      brightness.abs() < 0.01 &&
      (contrast - 1).abs() < 0.02 &&
      (saturation - 1).abs() < 0.02 &&
      temperature.abs() < 0.02;

  Map<String, double> toParams() => {
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'temperature': temperature,
  };

  /// A sentence describing the change, for a UI that should say what it is
  /// about to do rather than just offering an Apply button.
  String describe() {
    if (isNegligible) return 'These shots already match.';
    final parts = <String>[
      if (brightness.abs() >= 0.01)
        brightness > 0 ? 'brighter' : 'darker',
      if ((contrast - 1).abs() >= 0.02)
        contrast > 1 ? 'more contrast' : 'flatter',
      if ((saturation - 1).abs() >= 0.02)
        saturation > 1 ? 'more colour' : 'less colour',
      if (temperature.abs() >= 0.02)
        temperature > 0 ? 'warmer' : 'cooler',
    ];
    return 'Makes this shot ${parts.join(', ')}.';
  }
}

abstract final class ShotMatcher {
  /// What to apply to [shot] so it sits alongside [reference].
  ///
  /// Every term is clamped. An unclamped match between a night exterior and a
  /// lit interior produces a correction that destroys the shot rather than
  /// matching it — past a point the honest answer is "these do not match", and
  /// a clamped, visible partial correction says that better than a ruined
  /// frame does.
  static ShotMatch match({
    required FrameStats shot,
    required FrameStats reference,
  }) {
    // Exposure: close the gap in mean luma. The 1/255 scale converts to the
    // effect's −1…1 brightness range.
    final brightness =
        ((reference.yAverage - shot.yAverage) / 255).clamp(-0.35, 0.35);

    // Contrast: the ratio of the two frames' usable ranges.
    final contrast = (reference.range / shot.range).clamp(0.7, 1.6);

    // Saturation: same idea, guarding a near-monochrome shot from being
    // multiplied into neon.
    final saturation = shot.saturation < 4
        ? 1.0
        : (reference.saturation / shot.saturation).clamp(0.6, 1.7);

    // White balance: the effect's single temperature axis trades blue for
    // red, so the two chroma differences are combined into one figure —
    // reference-minus-shot on V (red) and shot-minus-reference on U (blue)
    // both push warm, so they reinforce rather than cancel.
    final warmth =
        ((reference.vAverage - shot.vAverage) +
            (shot.uAverage - reference.uAverage)) /
        2;
    final temperature = (warmth / 40).clamp(-0.6, 0.6);

    return ShotMatch(
      brightness: brightness.toDouble(),
      contrast: contrast.toDouble(),
      saturation: saturation.toDouble(),
      temperature: temperature.toDouble(),
    );
  }

  /// How far apart two shots are, 0 (identical) to 1 (nothing alike).
  ///
  /// Used to warn before applying a correction that is really a re-grade.
  static double distance(FrameStats a, FrameStats b) {
    final exposure = (a.yAverage - b.yAverage).abs() / 255;
    final cast =
        (math.max(
              (a.uAverage - b.uAverage).abs(),
              (a.vAverage - b.vAverage).abs(),
            )) /
        128;
    return math.min(1, math.max(exposure, cast));
  }
}
