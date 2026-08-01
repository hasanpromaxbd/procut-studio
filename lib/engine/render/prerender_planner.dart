/// Works out which stretches of a timeline the preview cannot keep up with.
///
/// Pure analysis: timeline in, spans out. The rendering itself is ordinary
/// range export, so the interesting decision — *what is too heavy to play* —
/// is the part that gets tested, and it gets tested without an encoder.
///
/// ## What counts as heavy
///
/// The preview composites layers live on the GPU and decodes each video layer
/// with its own hardware decoder. It falls over on two things: too many
/// simultaneous video decoders, and per-pixel work stacked deep. Everything
/// else — a title, a static crop, a plain cut — plays fine and is not worth
/// spending storage and battery to pre-render.
library;

import '../../domain/entities/clip.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/transform2d.dart';

/// A stretch of timeline worth rendering ahead, and why.
class PrerenderSpan {
  const PrerenderSpan({
    required this.start,
    required this.end,
    required this.cost,
    required this.reason,
  });

  final Duration start;
  final Duration end;

  /// Rough multiple of real time the preview needs. 1 means it keeps up.
  final double cost;

  /// Plain-language explanation, shown so the user knows why the app wants
  /// to spend their battery.
  final String reason;

  Duration get duration => end - start;

  @override
  String toString() =>
      'PrerenderSpan(${start.inMilliseconds}–${end.inMilliseconds}ms, '
      '${cost.toStringAsFixed(1)}×, $reason)';
}

abstract final class PrerenderPlanner {
  /// Above this many simultaneous video layers the decoder pool runs out and
  /// the preview starts dropping whole layers — matching the cap the preview
  /// stage enforces.
  static const int decoderBudget = 4;

  /// Cost at which playback stops being watchable. Below it, pre-rendering
  /// costs more than it returns.
  static const double heavyThreshold = 1.6;

  /// Spans the preview will struggle with, in timeline order.
  ///
  /// Adjacent heavy spans are merged: rendering two four-second stretches
  /// separated by half a second costs two encoder start-ups for nothing.
  static List<PrerenderSpan> plan(
    Timeline timeline, {
    Duration granularity = const Duration(seconds: 1),
  }) {
    if (timeline.duration <= Duration.zero) return const [];

    final probes = <(Duration, double, String)>[];
    for (
      var at = Duration.zero;
      at < timeline.duration;
      at += granularity
    ) {
      final (cost, reason) = costAt(timeline, at);
      probes.add((at, cost, reason));
    }

    final spans = <PrerenderSpan>[];
    Duration? runStart;
    var runCost = 0.0;
    var runReason = '';

    void close(Duration end) {
      final start = runStart;
      runStart = null;
      if (start == null) return;
      // A span shorter than the granularity is a rounding artefact, not a
      // stretch of heavy timeline.
      if (end - start < granularity) return;
      spans.add(
        PrerenderSpan(
          start: start,
          end: end,
          cost: runCost,
          reason: runReason,
        ),
      );
    }

    for (final (at, cost, reason) in probes) {
      if (cost >= heavyThreshold) {
        if (runStart == null) {
          runStart = at;
          runCost = cost;
          runReason = reason;
        } else if (cost > runCost) {
          // The worst moment in a span is the one worth naming.
          runCost = cost;
          runReason = reason;
        }
      } else {
        close(at);
      }
    }
    close(timeline.duration);

    return spans;
  }

  /// How hard the frame at [at] is to play, and the dominant reason.
  static (double cost, String reason) costAt(Timeline timeline, Duration at) {
    var videoLayers = 0;
    var effectPasses = 0;
    var masks = 0;
    var blendedLayers = 0;
    var speedRamps = 0;

    for (final track in timeline.tracks) {
      if (!track.type.isVisual || track.hidden) continue;
      final clip = track.clipAt(at);
      if (clip == null || !clip.enabled) continue;

      if (clip is VideoClip) videoLayers++;
      if (clip is CompoundClip) {
        // A group's members all decode at once; it is not one layer.
        videoLayers += clip.innerClips.whereType<VideoClip>().length;
      }
      effectPasses += clip.activeEffects.length;
      if (clip.mask.isActive) masks++;
      if (clip.transform.blendMode != LayerBlendMode.normal) blendedLayers++;
      if (clip is MediaClip && clip.hasSpeedRamp) speedRamps++;
    }

    // Decoders are the cliff: past the budget the preview drops layers
    // outright, so the cost climbs steeply rather than smoothly.
    final decoderCost = videoLayers <= decoderBudget
        ? 1 + videoLayers * 0.12
        : 1 + decoderBudget * 0.12 + (videoLayers - decoderBudget) * 0.9;

    final shaderCost = effectPasses * 0.18 + masks * 0.22 + blendedLayers * 0.2;
    final rampCost = speedRamps * 0.25;
    final cost = decoderCost + shaderCost + rampCost;

    final reason = switch (true) {
      _ when videoLayers > decoderBudget =>
        '$videoLayers video layers at once',
      _ when effectPasses >= 4 => '$effectPasses effect passes',
      _ when masks >= 2 => '$masks masks',
      _ when blendedLayers >= 2 => 'blend modes stacked',
      _ when speedRamps >= 1 => 'speed ramping',
      _ when effectPasses >= 2 => '$effectPasses effects',
      _ => 'layers stacked',
    };

    return (cost, reason);
  }

  /// Total time the spans cover — what the UI leads with, since it decides
  /// whether the user says yes.
  static Duration totalDuration(List<PrerenderSpan> spans) => spans.fold(
    Duration.zero,
    (sum, span) => sum + span.duration,
  );
}
