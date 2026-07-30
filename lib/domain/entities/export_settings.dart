/// Everything the export engine needs to turn a timeline into a file.
library;

import 'package:flutter/foundation.dart';

import '../../core/utils/math_utils.dart';

enum ExportResolution {
  p480('480P', 854, 480),
  p720('720P', 1280, 720),
  p1080('1080P', 1920, 1080),
  k2('2K', 2560, 1440),
  k4('4K', 3840, 2160),
  source('Source', 0, 0);

  const ExportResolution(this.label, this.longEdge, this.shortEdge);
  final String label;
  final int longEdge;
  final int shortEdge;

  static ExportResolution fromLabel(String? label) => ExportResolution.values
      .firstWhere((e) => e.label == label, orElse: () => ExportResolution.p1080);

  /// Resolves to concrete even dimensions for a canvas of [aspectRatio],
  /// preserving orientation: a 9:16 project at "1080P" is 1080×1920, not
  /// 1920×1080.
  (int width, int height) dimensionsFor(int canvasWidth, int canvasHeight) {
    if (this == ExportResolution.source || canvasHeight == 0) {
      return (
        MathUtils.roundToEven(canvasWidth),
        MathUtils.roundToEven(canvasHeight),
      );
    }
    final portrait = canvasHeight >= canvasWidth;
    final aspect = canvasWidth / canvasHeight;
    if (portrait) {
      final h = longEdge;
      return (MathUtils.roundToEven(h * aspect), MathUtils.roundToEven(h));
    }
    final w = longEdge;
    return (MathUtils.roundToEven(w), MathUtils.roundToEven(w / aspect));
  }

  /// Pixels per frame, used to scale the default bitrate.
  int get pixelCount => longEdge * shortEdge;
}

enum VideoCodec {
  h264('H264', 'libx264', 'h264_mediacodec', 'avc1'),
  hevc('HEVC', 'libx265', 'hevc_mediacodec', 'hvc1');

  const VideoCodec(this.label, this.softwareEncoder, this.hardwareEncoder, this.tag);
  final String label;

  /// libx264/libx265 — always available, slower, best quality per bit.
  final String softwareEncoder;

  /// Android MediaCodec — hardware, far faster, less efficient per bit.
  final String hardwareEncoder;

  /// Codec tag written into the container. HEVC in MP4 needs `hvc1` for
  /// QuickTime/iOS to play it; the default `hev1` shows a black frame.
  final String tag;

  static VideoCodec fromLabel(String? label) => VideoCodec.values
      .firstWhere((e) => e.label == label, orElse: () => VideoCodec.h264);

  /// HEVC delivers similar quality at roughly 60% of the bitrate.
  double get bitrateEfficiency => this == VideoCodec.hevc ? 0.6 : 1.0;
}

enum ExportContainer {
  mp4('MP4', 'mp4'),
  mov('MOV', 'mov'),

  /// Animated GIF: no audio, palette-quantised, huge per second — for short
  /// loops and stickers, and the settings sheet says so.
  gif('GIF', 'gif');

  const ExportContainer(this.label, this.extension);
  final String label;
  final String extension;

  static ExportContainer fromLabel(String? label) => ExportContainer.values
      .firstWhere((e) => e.label == label, orElse: () => ExportContainer.mp4);
}

enum AudioCodec {
  aac('AAC', 'aac'),
  alac('ALAC', 'alac');

  const AudioCodec(this.label, this.encoder);
  final String label;
  final String encoder;

  static AudioCodec fromLabel(String? label) => AudioCodec.values
      .firstWhere((e) => e.label == label, orElse: () => AudioCodec.aac);
}

/// Constant-quality (CRF) vs constant-bitrate targeting.
enum BitrateMode {
  /// Quality-targeted. Best default: size varies, quality does not.
  quality('Quality'),

  /// Bitrate-targeted. Needed when a platform enforces a hard size limit.
  custom('Custom bitrate');

  const BitrateMode(this.label);
  final String label;

  static BitrateMode fromLabel(String? label) => BitrateMode.values
      .firstWhere((e) => e.label == label, orElse: () => BitrateMode.quality);
}

/// Quality presets mapped to CRF values. Lower CRF = higher quality.
enum QualityPreset {
  low('Low', 30),
  medium('Medium', 26),
  high('High', 22),
  veryHigh('Very high', 19);

  const QualityPreset(this.label, this.crf);
  final String label;
  final int crf;

  static QualityPreset fromLabel(String? label) => QualityPreset.values
      .firstWhere((e) => e.label == label, orElse: () => QualityPreset.high);
}

@immutable
class ExportSettings {
  const ExportSettings({
    this.resolution = ExportResolution.p1080,
    this.fps = 30,
    this.videoCodec = VideoCodec.h264,
    this.audioCodec = AudioCodec.aac,
    this.container = ExportContainer.mp4,
    this.bitrateMode = BitrateMode.quality,
    this.quality = QualityPreset.high,
    this.customVideoBitrateKbps = 8000,
    this.audioBitrateKbps = 192,
    this.audioSampleRate = 48000,
    this.useHardwareEncoder = true,
    this.normalizeLoudness = false,
    this.fileNameOverride,
  });

  final ExportResolution resolution;
  final int fps;
  final VideoCodec videoCodec;
  final AudioCodec audioCodec;
  final ExportContainer container;
  final BitrateMode bitrateMode;
  final QualityPreset quality;
  final int customVideoBitrateKbps;
  final int audioBitrateKbps;
  final int audioSampleRate;

  /// Prefer MediaCodec. The engine falls back to software automatically if the
  /// hardware encoder rejects the stream — see `HardwareEncoderProbe`.
  final bool useHardwareEncoder;

  /// Level the mix to −14 LUFS, the loudness YouTube and Spotify normalise
  /// to anyway. Off by default: it re-levels the whole mix, and someone who
  /// balanced their audio by ear deserves to keep that balance untouched.
  final bool normalizeLoudness;

  final String? fileNameOverride;

  /// The bitrate we will actually ask for, in kbps.
  ///
  /// For quality mode this is only an estimate used for the size preview; the
  /// encoder is driven by CRF and the real size will differ.
  int effectiveVideoBitrateKbps(int canvasWidth, int canvasHeight) {
    if (bitrateMode == BitrateMode.custom) return customVideoBitrateKbps;
    final (w, h) = resolution.dimensionsFor(canvasWidth, canvasHeight);
    // ~0.10 bits per pixel per frame at "high" is a reasonable H.264 anchor
    // for camera-style content; scaled by codec efficiency and quality.
    final bitsPerPixel = switch (quality) {
      QualityPreset.low => 0.045,
      QualityPreset.medium => 0.07,
      QualityPreset.high => 0.10,
      QualityPreset.veryHigh => 0.15,
    };
    final bps = w * h * fps * bitsPerPixel * videoCodec.bitrateEfficiency;
    return (bps / 1000).round().clamp(500, 120000);
  }

  /// Rough output size for the export screen.
  int estimatedBytes(Duration duration, int canvasWidth, int canvasHeight) {
    final videoKbps = effectiveVideoBitrateKbps(canvasWidth, canvasHeight);
    final totalKbps = videoKbps + audioBitrateKbps;
    return (totalKbps * 1000 / 8 * duration.inMilliseconds / 1000).round();
  }

  (int width, int height) dimensionsFor(int canvasWidth, int canvasHeight) =>
      resolution.dimensionsFor(canvasWidth, canvasHeight);

  /// Guards the combinations that simply do not work on Android.
  List<String> validate() {
    final issues = <String>[];
    if (fps <= 0 || fps > 120) {
      issues.add('Frame rate must be between 1 and 120.');
    }
    if (bitrateMode == BitrateMode.custom &&
        (customVideoBitrateKbps < 200 || customVideoBitrateKbps > 200000)) {
      issues.add('Bitrate must be between 200 kbps and 200 Mbps.');
    }
    if (audioCodec == AudioCodec.alac && container == ExportContainer.mp4) {
      // ALAC in MP4 is legal but poorly supported by Android players.
      issues.add('ALAC audio is only reliable in a MOV container.');
    }
    if (container == ExportContainer.gif) {
      if (fps > 15) {
        issues.add('GIF above 15 fps balloons in size — lower the rate.');
      }
      if (resolution.longEdge > 1280) {
        issues.add('GIF at this resolution will be enormous — use 720p or less.');
      }
    }
    return issues;
  }

  ExportSettings copyWith({
    ExportResolution? resolution,
    int? fps,
    VideoCodec? videoCodec,
    AudioCodec? audioCodec,
    ExportContainer? container,
    BitrateMode? bitrateMode,
    QualityPreset? quality,
    int? customVideoBitrateKbps,
    int? audioBitrateKbps,
    int? audioSampleRate,
    bool? useHardwareEncoder,
    bool? normalizeLoudness,
    String? fileNameOverride,
  }) => ExportSettings(
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
    videoCodec: videoCodec ?? this.videoCodec,
    audioCodec: audioCodec ?? this.audioCodec,
    container: container ?? this.container,
    bitrateMode: bitrateMode ?? this.bitrateMode,
    quality: quality ?? this.quality,
    customVideoBitrateKbps:
        customVideoBitrateKbps ?? this.customVideoBitrateKbps,
    audioBitrateKbps: audioBitrateKbps ?? this.audioBitrateKbps,
    audioSampleRate: audioSampleRate ?? this.audioSampleRate,
    useHardwareEncoder: useHardwareEncoder ?? this.useHardwareEncoder,
    normalizeLoudness: normalizeLoudness ?? this.normalizeLoudness,
    fileNameOverride: fileNameOverride ?? this.fileNameOverride,
  );

  Map<String, dynamic> toJson() => {
    'resolution': resolution.label,
    'fps': fps,
    'vcodec': videoCodec.label,
    'acodec': audioCodec.label,
    'container': container.label,
    'bitrateMode': bitrateMode.label,
    'quality': quality.label,
    'vBitrate': customVideoBitrateKbps,
    'aBitrate': audioBitrateKbps,
    'sampleRate': audioSampleRate,
    'hw': useHardwareEncoder,
    if (normalizeLoudness) 'loudnorm': true,
    if (fileNameOverride != null) 'fileName': fileNameOverride,
  };

  factory ExportSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ExportSettings();
    return ExportSettings(
      resolution: ExportResolution.fromLabel(json['resolution'] as String?),
      fps: (json['fps'] as num?)?.toInt() ?? 30,
      videoCodec: VideoCodec.fromLabel(json['vcodec'] as String?),
      audioCodec: AudioCodec.fromLabel(json['acodec'] as String?),
      container: ExportContainer.fromLabel(json['container'] as String?),
      bitrateMode: BitrateMode.fromLabel(json['bitrateMode'] as String?),
      quality: QualityPreset.fromLabel(json['quality'] as String?),
      customVideoBitrateKbps: (json['vBitrate'] as num?)?.toInt() ?? 8000,
      audioBitrateKbps: (json['aBitrate'] as num?)?.toInt() ?? 192,
      audioSampleRate: (json['sampleRate'] as num?)?.toInt() ?? 48000,
      useHardwareEncoder: json['hw'] as bool? ?? true,
      normalizeLoudness: json['loudnorm'] as bool? ?? false,
      fileNameOverride: json['fileName'] as String?,
    );
  }
}
