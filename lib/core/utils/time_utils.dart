/// Time/frame conversion and formatting.
///
/// The timeline stores every position as a [Duration] (microsecond integers),
/// never as a double of seconds — accumulating float seconds across a hundred
/// edits drifts enough to visibly desync audio on a long project.
library;

import 'dart:math' as math;

abstract final class TimeUtils {
  /// `HH:MM:SS.mmm`, dropping the hour field unless the value needs it.
  static String formatTimecode(Duration d, {bool forceHours = false}) {
    final negative = d.isNegative;
    final abs = d.abs();
    final hours = abs.inHours;
    final minutes = abs.inMinutes.remainder(60);
    final seconds = abs.inSeconds.remainder(60);
    final millis = abs.inMilliseconds.remainder(1000);

    final buffer = StringBuffer(negative ? '-' : '');
    if (forceHours || hours > 0) {
      buffer.write('${hours.toString().padLeft(2, '0')}:');
    }
    buffer
      ..write(minutes.toString().padLeft(2, '0'))
      ..write(':')
      ..write(seconds.toString().padLeft(2, '0'))
      ..write('.')
      ..write((millis ~/ 10).toString().padLeft(2, '0'));
    return buffer.toString();
  }

  /// SMPTE-style `HH:MM:SS:FF` used in the inspector, where frame accuracy
  /// matters more than milliseconds.
  static String formatSmpte(Duration d, int fps) {
    assert(fps > 0, 'fps must be positive');
    final abs = d.abs();
    final totalFrames = durationToFrame(abs, fps);
    final frames = totalFrames % fps;
    final totalSeconds = totalFrames ~/ fps;
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = totalSeconds ~/ 3600;
    return '${d.isNegative ? '-' : ''}'
        '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}:'
        '${frames.toString().padLeft(2, '0')}';
  }

  /// Compact duration for cards and lists: `1:04`, `12:03`, `1:02:33`.
  static String formatShort(Duration d) {
    final abs = d.abs();
    final hours = abs.inHours;
    final minutes = abs.inMinutes.remainder(60);
    final seconds = abs.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}'
          ':${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Seconds with three decimals — the format FFmpeg expects for `-ss`/`-t`.
  static String toFfmpegSeconds(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);

  static int durationToFrame(Duration d, int fps) =>
      (d.inMicroseconds * fps / Duration.microsecondsPerSecond).round();

  static Duration frameToDuration(int frame, int fps) => Duration(
    microseconds: (frame * Duration.microsecondsPerSecond / fps).round(),
  );

  /// Rounds [d] to the nearest whole frame at [fps]. Every edit runs through
  /// this so clip boundaries always land on real frame times.
  static Duration snapToFrame(Duration d, int fps) =>
      frameToDuration(durationToFrame(d, fps), fps);

  static Duration fromSeconds(double seconds) => Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );

  static double toSeconds(Duration d) =>
      d.inMicroseconds / Duration.microsecondsPerSecond;

  static Duration clamp(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  static Duration max(Duration a, Duration b) => a > b ? a : b;
  static Duration min(Duration a, Duration b) => a < b ? a : b;

  /// Scales a duration by a playback rate, e.g. a 10s source at 2x occupies 5s
  /// of timeline. Guards against a zero rate producing an infinite clip.
  static Duration scale(Duration d, double rate) {
    final safeRate = rate.abs() < 1e-6 ? 1e-6 : rate.abs();
    return Duration(microseconds: (d.inMicroseconds / safeRate).round());
  }

  /// Inverse of [scale]: timeline duration → source duration.
  static Duration unscale(Duration d, double rate) =>
      Duration(microseconds: (d.inMicroseconds * rate.abs()).round());

  static Duration lerp(Duration a, Duration b, double t) => Duration(
    microseconds: (a.inMicroseconds +
            (b.inMicroseconds - a.inMicroseconds) * t)
        .round(),
  );

  /// Human file-size, used by the export screen's size estimate.
  static String formatBytes(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = math.min((math.log(bytes) / math.log(1024)).floor(), units.length - 1);
    final value = bytes / math.pow(1024, i);
    return '${value.toStringAsFixed(i == 0 ? 0 : decimals)} ${units[i]}';
  }

  const TimeUtils._();
}
