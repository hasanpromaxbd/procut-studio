/// Contract for the AI-assisted tools.
///
/// **Read this before wiring the UI.** These features fall into two very
/// different buckets, and the app is explicit about which is which rather than
/// pretending everything works offline:
///
///  * **Local (always available)** — scene detection, colour enhancement and
///    upscaling are implemented with FFmpeg filters that ship inside the app.
///    They are deterministic signal processing, not learned models.
///  * **Model-backed** — captions, background removal, object/face tracking and
///    voice isolation need a neural model. The app ships no model weights, so
///    these resolve through an [AiBackend] that the user configures (a
///    self-hosted inference endpoint) or that a future build bundles on-device.
///    With no backend configured they fail with `FeatureUnavailableFailure`,
///    and the UI shows a "set up in Settings" affordance instead of a spinner
///    that never ends.
library;

import 'package:flutter/foundation.dart';

import '../../core/error/result.dart';
import '../entities/media_asset.dart';
import '../entities/subtitle.dart';

enum AiCapability {
  autoCaption('AI Auto Caption', requiresModel: true),
  backgroundRemoval('AI Background Removal', requiresModel: true),
  objectTracking('AI Object Tracking', requiresModel: true),
  faceTracking('AI Face Tracking', requiresModel: true),
  colorEnhancement('AI Color Enhancement', requiresModel: false),
  upscaling('AI Upscaling', requiresModel: false),
  voiceIsolation('AI Voice Isolation', requiresModel: false),
  sceneDetection('AI Scene Detection', requiresModel: false);

  const AiCapability(this.label, {required this.requiresModel});
  final String label;

  /// True when the feature cannot run without an external model.
  final bool requiresModel;
}

/// A point in normalised canvas coordinates at a moment in time.
@immutable
class TrackedPoint {
  const TrackedPoint({
    required this.time,
    required this.x,
    required this.y,
    this.width = 0,
    this.height = 0,
    this.confidence = 1,
  });

  final Duration time;

  /// 0..1 of frame width/height.
  final double x;
  final double y;
  final double width;
  final double height;
  final double confidence;
}

@immutable
class TrackingResult {
  const TrackingResult({required this.points, this.label});
  final List<TrackedPoint> points;
  final String? label;

  bool get isEmpty => points.isEmpty;
}

@immutable
class SceneCut {
  const SceneCut({required this.time, required this.score});
  final Duration time;

  /// 0..1 dissimilarity against the previous frame.
  final double score;
}

abstract interface class AiRepository {
  /// Capabilities usable right now on this device with the current config.
  Future<Set<AiCapability>> availableCapabilities();

  /// True when a model-backed feature has somewhere to run.
  Future<bool> hasBackend();

  // ── Model-backed ─────────────────────────────────────────────────────

  Future<Result<SubtitleTrack>> autoCaption(
    MediaAsset asset, {
    String? languageHint,
    void Function(double progress)? onProgress,
  });

  /// Returns the path to an alpha-matte video (white = keep) that the
  /// compositor uses as a mask.
  Future<Result<String>> removeBackground(
    MediaAsset asset, {
    void Function(double progress)? onProgress,
  });

  /// Tracks the region [x, y, width, height] (normalised) from [from].
  Future<Result<TrackingResult>> trackObject(
    MediaAsset asset, {
    required double x,
    required double y,
    required double width,
    required double height,
    required Duration from,
    Duration? to,
    void Function(double progress)? onProgress,
  });

  Future<Result<List<TrackingResult>>> trackFaces(
    MediaAsset asset, {
    Duration? from,
    Duration? to,
    void Function(double progress)? onProgress,
  });

  // ── Local signal processing ──────────────────────────────────────────

  /// Analyses the clip and returns colour-correction parameters
  /// (`brightness`, `contrast`, `saturation`, `gamma`) to apply as an effect.
  Future<Result<Map<String, double>>> suggestColorEnhancement(
    MediaAsset asset, {
    Duration? sampleAt,
  });

  /// Renders an upscaled copy. Uses Lanczos resampling plus mild unsharp —
  /// good, but not a hallucinating super-resolution network.
  Future<Result<String>> upscale(
    MediaAsset asset, {
    required int targetHeight,
    void Function(double progress)? onProgress,
  });

  /// Suppresses background noise around speech and returns a new audio file.
  Future<Result<String>> isolateVoice(
    MediaAsset asset, {
    double strength = 0.7,
    void Function(double progress)? onProgress,
  });

  /// Finds hard cuts. Genuinely local — FFmpeg's scene-score filter.
  Future<Result<List<SceneCut>>> detectScenes(
    MediaAsset asset, {
    double threshold = 0.35,
    void Function(double progress)? onProgress,
  });
}
