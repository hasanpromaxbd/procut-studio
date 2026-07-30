/// Finds the silences in a recording, so the editor can offer to cut them.
///
/// Pure: peaks in, spans out. The peaks are the same 40-per-second envelope
/// the timeline already draws, so detection costs nothing extra to prepare
/// and the spans line up exactly with what the user sees in the waveform.
///
/// ## Why the threshold is relative
///
/// An absolute threshold breaks on the first quiet recording: a lavalier at
/// low gain is "all silence" at −40 dBFS while its speech is perfectly
/// audible. Measuring the clip's own loud portion and cutting relative to it
/// tracks what a human calls silence — the gaps *in this recording*.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/constants/app_constants.dart';

/// One stretch of silence, in source time.
class SilenceSpan {
  const SilenceSpan({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get length => end - start;

  @override
  String toString() =>
      'SilenceSpan(${start.inMilliseconds}–${end.inMilliseconds}ms)';

  @override
  bool operator ==(Object other) =>
      other is SilenceSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

abstract final class SilenceDetector {
  /// Finds spans quieter than [threshold] × the clip's speech level.
  ///
  /// [minSilence] drops the blinks — the natural gaps inside a sentence that
  /// would turn one take into confetti. [padding] pulls each cut inward so
  /// speech never starts clipped mid-syllable; it is the difference between
  /// a tight edit and one that sounds chopped.
  static List<SilenceSpan> detect(
    Float32List peaks, {
    double threshold = 0.12,
    Duration minSilence = const Duration(milliseconds: 450),
    Duration padding = const Duration(milliseconds: 120),
  }) {
    if (peaks.isEmpty) return const [];
    const sps = AppConstants.waveformSamplesPerSecond;

    // "Speech level" is the 90th percentile, not the maximum: one door slam
    // must not redefine what counts as quiet for the whole take.
    final sorted = peaks.toList()..sort();
    final speech = sorted[(sorted.length * 0.9).floor().clamp(
      0,
      sorted.length - 1,
    )];
    if (speech <= 1e-6) {
      // The whole clip is silent; one span, no padding — there is no speech
      // to protect.
      return [
        SilenceSpan(
          start: Duration.zero,
          end: Duration(microseconds: (peaks.length / sps * 1e6).round()),
        ),
      ];
    }

    final cutoff = speech * threshold;
    final minSamples = math.max(1, (minSilence.inMilliseconds * sps) ~/ 1000);

    final spans = <SilenceSpan>[];
    int? runStart;

    void close(int endExclusive) {
      final start = runStart;
      runStart = null;
      if (start == null || endExclusive - start < minSamples) return;

      var from = Duration(microseconds: (start / sps * 1e6).round()) + padding;
      var to = Duration(microseconds: (endExclusive / sps * 1e6).round()) -
          padding;
      // Interior spans lose padding on both sides; a span at the very edge of
      // the clip keeps its outer edge — there is nothing there to clip into.
      if (start == 0) from = Duration.zero;
      if (endExclusive == peaks.length) {
        to = Duration(microseconds: (endExclusive / sps * 1e6).round());
      }
      if (to <= from) return;
      spans.add(SilenceSpan(start: from, end: to));
    }

    for (var i = 0; i < peaks.length; i++) {
      if (peaks[i] <= cutoff) {
        runStart ??= i;
      } else if (runStart != null) {
        close(i);
      }
    }
    close(peaks.length);

    return spans;
  }

  /// How much of the clip the spans would remove — the number the UI leads
  /// with, because "cuts 41 seconds of dead air" is the pitch.
  static Duration totalRemoved(List<SilenceSpan> spans) => spans.fold(
    Duration.zero,
    (sum, span) => sum + span.length,
  );
}
