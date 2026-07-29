/// A source file that has been imported and probed.
///
/// Assets are immutable and content-addressed by path+mtime+size, so importing
/// the same file twice reuses one asset (and therefore one thumbnail cache and
/// one proxy) instead of duplicating work.
library;

import 'package:flutter/foundation.dart';

import '../../core/utils/file_utils.dart';
import '../../core/utils/math_utils.dart';

enum AssetKind {
  video('video'),
  audio('audio'),
  image('image');

  const AssetKind(this.id);
  final String id;

  static AssetKind fromId(String? id) =>
      AssetKind.values.firstWhere((e) => e.id == id, orElse: () => AssetKind.video);

  static AssetKind? fromPath(String path) => switch (FileUtils.kindOf(path)) {
    MediaKind.video => AssetKind.video,
    MediaKind.audio => AssetKind.audio,
    MediaKind.image => AssetKind.image,
    MediaKind.unknown => null,
  };
}

@immutable
class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.path,
    required this.kind,
    required this.duration,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.videoCodec,
    this.audioCodec,
    this.bitrate = 0,
    this.audioSampleRate = 0,
    this.audioChannels = 0,
    this.rotationDegrees = 0,
    this.fileSizeBytes = 0,
    this.hasAudioStream = false,
    this.hasVideoStream = false,
    this.displayName = '',
    this.importedAt,
    this.proxyPath,
  });

  final String id;
  final String path;
  final AssetKind kind;

  /// Zero for stills — an image clip's duration is chosen by the user.
  final Duration duration;

  final int width;
  final int height;
  final double fps;
  final String? videoCodec;
  final String? audioCodec;
  final int bitrate;
  final int audioSampleRate;
  final int audioChannels;

  /// Container-level rotation metadata (90/180/270). Phone footage is very
  /// often stored landscape with a rotation tag, and ignoring it is the classic
  /// "my video exported sideways" bug.
  final int rotationDegrees;

  final int fileSizeBytes;
  final bool hasAudioStream;
  final bool hasVideoStream;
  final String displayName;
  final DateTime? importedAt;

  /// Low-resolution stand-in used for smooth scrubbing on 4K sources.
  final String? proxyPath;

  /// Dimensions after applying container rotation — what the user actually
  /// sees, and what the canvas should be sized against.
  int get displayWidth =>
      (rotationDegrees == 90 || rotationDegrees == 270) ? height : width;
  int get displayHeight =>
      (rotationDegrees == 90 || rotationDegrees == 270) ? width : height;

  bool get isPortrait => displayHeight > displayWidth;
  bool get isStill => kind == AssetKind.image;
  bool get hasProxy => proxyPath != null && proxyPath!.isNotEmpty;

  double get aspectRatio =>
      displayHeight == 0 ? 16 / 9 : displayWidth / displayHeight;

  String get aspectRatioLabel =>
      MathUtils.aspectRatioLabel(displayWidth, displayHeight);

  /// True when the source is heavy enough that scrubbing wants a proxy.
  bool get needsProxy =>
      kind == AssetKind.video && (displayWidth >= 2560 || displayHeight >= 2560);

  /// Path the preview should decode: the proxy when we have one.
  String get previewPath => hasProxy ? proxyPath! : path;

  MediaAsset copyWith({
    String? id,
    String? path,
    AssetKind? kind,
    Duration? duration,
    int? width,
    int? height,
    double? fps,
    String? videoCodec,
    String? audioCodec,
    int? bitrate,
    int? audioSampleRate,
    int? audioChannels,
    int? rotationDegrees,
    int? fileSizeBytes,
    bool? hasAudioStream,
    bool? hasVideoStream,
    String? displayName,
    DateTime? importedAt,
    String? proxyPath,
  }) => MediaAsset(
    id: id ?? this.id,
    path: path ?? this.path,
    kind: kind ?? this.kind,
    duration: duration ?? this.duration,
    width: width ?? this.width,
    height: height ?? this.height,
    fps: fps ?? this.fps,
    videoCodec: videoCodec ?? this.videoCodec,
    audioCodec: audioCodec ?? this.audioCodec,
    bitrate: bitrate ?? this.bitrate,
    audioSampleRate: audioSampleRate ?? this.audioSampleRate,
    audioChannels: audioChannels ?? this.audioChannels,
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    hasAudioStream: hasAudioStream ?? this.hasAudioStream,
    hasVideoStream: hasVideoStream ?? this.hasVideoStream,
    displayName: displayName ?? this.displayName,
    importedAt: importedAt ?? this.importedAt,
    proxyPath: proxyPath ?? this.proxyPath,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'kind': kind.id,
    'durUs': duration.inMicroseconds,
    'w': width,
    'h': height,
    'fps': fps,
    'vcodec': videoCodec,
    'acodec': audioCodec,
    'bitrate': bitrate,
    'sampleRate': audioSampleRate,
    'channels': audioChannels,
    'rot': rotationDegrees,
    'size': fileSizeBytes,
    'hasAudio': hasAudioStream,
    'hasVideo': hasVideoStream,
    'name': displayName,
    'importedAt': importedAt?.millisecondsSinceEpoch,
    'proxy': proxyPath,
  };

  factory MediaAsset.fromJson(Map<String, dynamic> json) => MediaAsset(
    id: json['id'] as String,
    path: json['path'] as String,
    kind: AssetKind.fromId(json['kind'] as String?),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    width: (json['w'] as num?)?.toInt() ?? 0,
    height: (json['h'] as num?)?.toInt() ?? 0,
    fps: (json['fps'] as num?)?.toDouble() ?? 0,
    videoCodec: json['vcodec'] as String?,
    audioCodec: json['acodec'] as String?,
    bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
    audioSampleRate: (json['sampleRate'] as num?)?.toInt() ?? 0,
    audioChannels: (json['channels'] as num?)?.toInt() ?? 0,
    rotationDegrees: (json['rot'] as num?)?.toInt() ?? 0,
    fileSizeBytes: (json['size'] as num?)?.toInt() ?? 0,
    hasAudioStream: json['hasAudio'] as bool? ?? false,
    hasVideoStream: json['hasVideo'] as bool? ?? false,
    displayName: json['name'] as String? ?? '',
    importedAt: json['importedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['importedAt'] as num).toInt()),
    proxyPath: json['proxy'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MediaAsset && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'MediaAsset($id, ${kind.id}, ${displayWidth}x$displayHeight, '
      '${duration.inMilliseconds}ms)';
}
