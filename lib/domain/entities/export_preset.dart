/// Named export targets.
///
/// These are not just resolution shortcuts. Each platform re-encodes whatever
/// it receives, so the useful thing a preset does is stop the user *fighting*
/// that: give the platform a clean master at the aspect it wants, and let it do
/// its own compression. Uploading a 60 Mbps 4K file to a service that will
/// transcode it to 6 Mbps wastes upload time and gains nothing.
library;

import 'package:flutter/foundation.dart';

import 'export_settings.dart';
import 'timeline.dart';

@immutable
class ExportPreset {
  const ExportPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.aspect,
    required this.settings,
    this.maxDuration,
    this.note,
  });

  final String id;
  final String name;
  final String description;

  /// The canvas shape this target expects.
  final AspectPreset aspect;

  final ExportSettings settings;

  /// Platform limit, where one exists and is short enough to matter.
  final Duration? maxDuration;

  /// Surfaced when the project does not match the preset — the honest caveat
  /// rather than silently reformatting.
  final String? note;

  /// True when the project's canvas already matches this target.
  bool matches(Timeline timeline) =>
      (timeline.aspectRatio - aspect.ratio).abs() < 0.02;

  /// Whether the project would be cut short by a platform limit.
  bool exceedsLimit(Duration duration) =>
      maxDuration != null && duration > maxDuration!;

  static const List<ExportPreset> all = [
    ExportPreset(
      id: 'master',
      name: 'Master',
      description: 'Highest quality, for archiving or re-editing',
      aspect: AspectPreset.horizontal16x9,
      settings: ExportSettings(
        resolution: ExportResolution.source,
        quality: QualityPreset.veryHigh,
        audioBitrateKbps: 256,
      ),
      note: 'Keeps the project resolution. Large file — this is the copy you '
          'keep, not the one you upload.',
    ),
    ExportPreset(
      id: 'reels',
      name: 'Instagram Reels',
      description: '9:16 · 1080p · up to 90s',
      aspect: AspectPreset.vertical9x16,
      settings: ExportSettings(
        resolution: ExportResolution.p1080,
        fps: 30,
        quality: QualityPreset.high,
      ),
      maxDuration: Duration(seconds: 90),
    ),
    ExportPreset(
      id: 'shorts',
      name: 'YouTube Shorts',
      description: '9:16 · 1080p · up to 3min',
      aspect: AspectPreset.vertical9x16,
      settings: ExportSettings(
        resolution: ExportResolution.p1080,
        fps: 30,
        quality: QualityPreset.high,
      ),
      maxDuration: Duration(minutes: 3),
    ),
    ExportPreset(
      id: 'tiktok',
      name: 'TikTok',
      description: '9:16 · 1080p',
      aspect: AspectPreset.vertical9x16,
      settings: ExportSettings(
        resolution: ExportResolution.p1080,
        fps: 30,
        quality: QualityPreset.high,
      ),
      maxDuration: Duration(minutes: 10),
    ),
    ExportPreset(
      id: 'youtube',
      name: 'YouTube',
      description: '16:9 · 1080p · H.264',
      aspect: AspectPreset.horizontal16x9,
      settings: ExportSettings(
        resolution: ExportResolution.p1080,
        fps: 30,
        quality: QualityPreset.veryHigh,
        audioBitrateKbps: 192,
      ),
      note: 'YouTube re-encodes everything, so a clean 1080p master beats a '
          'huge 4K upload unless the source really is 4K.',
    ),
    ExportPreset(
      id: 'youtube4k',
      name: 'YouTube 4K',
      description: '16:9 · 2160p · HEVC',
      aspect: AspectPreset.horizontal16x9,
      settings: ExportSettings(
        resolution: ExportResolution.k4,
        fps: 30,
        videoCodec: VideoCodec.hevc,
        quality: QualityPreset.high,
      ),
      note: 'Only worth it if the footage is genuinely 4K — upscaling to 4K '
          'adds size, not detail.',
    ),
    ExportPreset(
      id: 'square',
      name: 'Square post',
      description: '1:1 · 1080p',
      aspect: AspectPreset.square1x1,
      settings: ExportSettings(
        resolution: ExportResolution.p1080,
        fps: 30,
        quality: QualityPreset.high,
      ),
    ),
    ExportPreset(
      id: 'small',
      name: 'Small file',
      description: '720p · for messaging and email',
      aspect: AspectPreset.vertical9x16,
      settings: ExportSettings(
        resolution: ExportResolution.p720,
        fps: 30,
        quality: QualityPreset.medium,
        audioBitrateKbps: 128,
      ),
    ),
  ];

  static ExportPreset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}
