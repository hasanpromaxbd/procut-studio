/// Lines up two recordings of the same moment by their sound.
///
/// Two cameras on one scene hear the same thing at slightly different times.
/// Cross-correlating their loudness envelopes finds that offset — which is
/// what turns a pile of clips into a multicam group without anyone clapping.
///
/// Pure: envelopes in, offset out. The envelopes are the same 40-per-second
/// peaks the timeline already draws, so nothing extra has to be extracted.
///
/// ## Why envelopes rather than samples
///
/// Sample-level correlation is what a desktop NLE does, and it is both more
/// accurate and far more expensive — megabytes of PCM per clip and an FFT to
/// stay tractable. At 40 Hz the envelope pins the offset to about ±25 ms,
/// which is inside a frame at 30 fps and therefore inside what the timeline
/// can represent anyway.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/constants/app_constants.dart';

/// How two recordings line up.
class SyncResult {
  const SyncResult({
    required this.offset,
    required this.confidence,
    required this.overlap,
  });

  /// How far [b] lags [a]. Negative means b started first.
  final Duration offset;

  /// Peak correlation, 0–1. Below ~0.5 the two probably are not the same
  /// moment, and the caller should say so rather than align them anyway.
  final double confidence;

  /// How much material the two share at that offset. A confident match on
  /// half a second of overlap is not a match.
  final Duration overlap;

  bool get isTrustworthy =>
      confidence >= 0.5 && overlap >= const Duration(seconds: 2);
}

abstract final class AudioSync {
  static const _sps = AppConstants.waveformSamplesPerSecond;

  /// Finds the offset that best aligns [b] with [a].
  ///
  /// [maxOffset] bounds the search: two angles on one scene start within a
  /// minute of each other, and searching further mostly finds coincidences
  /// in unrelated audio.
  static SyncResult align(
    Float32List a,
    Float32List b, {
    Duration maxOffset = const Duration(seconds: 60),
  }) {
    if (a.isEmpty || b.isEmpty) {
      return const SyncResult(
        offset: Duration.zero,
        confidence: 0,
        overlap: Duration.zero,
      );
    }

    final maxShift = math.min(
      (maxOffset.inMilliseconds * _sps) ~/ 1000,
      math.max(a.length, b.length),
    );

    // Normalising first is what makes the correlation about *shape* rather
    // than level: one camera's mic being quieter must not lower the score.
    final na = _normalise(a);
    final nb = _normalise(b);

    var bestShift = 0;
    var bestScore = -1.0;
    var bestOverlap = 0;

    for (var shift = -maxShift; shift <= maxShift; shift++) {
      final from = math.max(0, -shift);
      final to = math.min(na.length, nb.length - shift);
      final count = to - from;
      // Too little shared material to judge; a two-sample overlap correlates
      // perfectly with almost anything.
      if (count < _sps) continue;

      var dot = 0.0;
      for (var i = from; i < to; i++) {
        dot += na[i] * nb[i + shift];
      }
      // Divide by the overlap so a long alignment is not automatically
      // preferred over a better short one.
      final score = dot / count;

      if (score > bestScore) {
        bestScore = score;
        bestShift = shift;
        bestOverlap = count;
      }
    }

    return SyncResult(
      // A positive shift means b's sample i+shift matched a's i, i.e. b
      // started *earlier* — hence the negation.
      offset: Duration(microseconds: (-bestShift / _sps * 1e6).round()),
      confidence: bestScore.clamp(0.0, 1.0),
      overlap: Duration(microseconds: (bestOverlap / _sps * 1e6).round()),
    );
  }

  /// Zero-mean, unit-scale copy of an envelope.
  ///
  /// Subtracting the mean is what stops a constant hiss floor dominating the
  /// correlation — without it two recordings of *silence* score higher than
  /// two of the same speech.
  static Float32List _normalise(Float32List input) {
    var sum = 0.0;
    for (final value in input) {
      sum += value;
    }
    final mean = sum / input.length;

    var energy = 0.0;
    for (final value in input) {
      final centred = value - mean;
      energy += centred * centred;
    }
    final scale = energy <= 1e-12 ? 1.0 : 1 / math.sqrt(energy / input.length);

    final out = Float32List(input.length);
    for (var i = 0; i < input.length; i++) {
      out[i] = (input[i] - mean) * scale;
    }
    return out;
  }
}
