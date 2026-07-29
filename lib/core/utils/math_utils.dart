import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

abstract final class MathUtils {
  static double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  static double clamp(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  static int clampInt(int v, int min, int max) =>
      v < min ? min : (v > max ? max : v);

  static double lerp(double a, double b, double t) => a + (b - a) * t;

  /// Maps [v] from one range to another without clamping.
  static double remap(
    double v,
    double inMin,
    double inMax,
    double outMin,
    double outMax,
  ) {
    if ((inMax - inMin).abs() < 1e-9) return outMin;
    return outMin + (v - inMin) * (outMax - outMin) / (inMax - inMin);
  }

  /// Rounds up to the nearest even integer. H.264/HEVC require even dimensions
  /// with 4:2:0 chroma, and libx264 fails outright on odd ones.
  static int roundToEven(num v) {
    final i = v.round();
    return i.isEven ? i : i + 1;
  }

  /// Fits [source] inside [bounds] preserving aspect ratio (letterbox).
  static Size fitInside(Size source, Size bounds) {
    if (source.width <= 0 || source.height <= 0) return Size.zero;
    final scale = math.min(
      bounds.width / source.width,
      bounds.height / source.height,
    );
    return Size(source.width * scale, source.height * scale);
  }

  /// Fills [bounds] with [source] preserving aspect ratio (centre-crop).
  static Size coverBounds(Size source, Size bounds) {
    if (source.width <= 0 || source.height <= 0) return Size.zero;
    final scale = math.max(
      bounds.width / source.width,
      bounds.height / source.height,
    );
    return Size(source.width * scale, source.height * scale);
  }

  static double distance(Offset a, Offset b) => (a - b).distance;

  static double degreesToRadians(double degrees) => degrees * math.pi / 180.0;
  static double radiansToDegrees(double radians) => radians * 180.0 / math.pi;

  /// Greatest common divisor — used to reduce an aspect ratio to `16:9`.
  static int gcd(int a, int b) {
    a = a.abs();
    b = b.abs();
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a == 0 ? 1 : a;
  }

  static String aspectRatioLabel(int width, int height) {
    if (width <= 0 || height <= 0) return '—';
    final d = gcd(width, height);
    return '${width ~/ d}:${height ~/ d}';
  }

  /// Decibels → linear gain, for the audio mixer.
  static double dbToLinear(double db) => math.pow(10, db / 20).toDouble();

  static double linearToDb(double linear) =>
      linear <= 1e-6 ? -96.0 : 20 * (math.log(linear) / math.ln10);

  const MathUtils._();
}
