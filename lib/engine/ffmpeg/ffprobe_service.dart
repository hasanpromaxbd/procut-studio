/// Reads container/stream metadata and turns it into a [MediaAsset].
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/file_utils.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/media_asset.dart';

class FFprobeService {
  FFprobeService();

  static const _log = Log('FFprobeService');

  Future<Result<MediaAsset>> probe(String path, {String? assetId}) async {
    final file = File(path);
    if (!await file.exists()) {
      return Result.err(
        UnsupportedMediaFailure('That file no longer exists.', path: path),
      );
    }

    final kindGuess = AssetKind.fromPath(path);
    if (kindGuess == null) {
      return Result.err(
        UnsupportedMediaFailure(
          'ProCut does not support ${FileUtils.extensionOf(path)} files.',
          path: path,
        ),
      );
    }

    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) {
        return Result.err(
          UnsupportedMediaFailure(
            'That file could not be read as media.',
            path: path,
          ),
        );
      }

      final props = info.getAllProperties()?.cast<String, dynamic>() ?? {};
      return Result.ok(
        _assetFromProbe(
          path: path,
          assetId: assetId ?? IdGenerator.asset(),
          props: props,
          kindGuess: kindGuess,
          fileSize: await file.length(),
        ),
      );
    } catch (e, s) {
      _log.e('probe failed', error: e, stackTrace: s, fields: {'path': path});
      return Result.err(
        UnsupportedMediaFailure(
          'That file could not be read as media.',
          path: path,
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  MediaAsset _assetFromProbe({
    required String path,
    required String assetId,
    required Map<String, dynamic> props,
    required AssetKind kindGuess,
    required int fileSize,
  }) {
    final format = (props['format'] as Map?)?.cast<String, dynamic>() ?? {};
    final streams = ((props['streams'] as List?) ?? const [])
        .map((s) => (s as Map).cast<String, dynamic>())
        .toList();

    Map<String, dynamic>? videoStream;
    Map<String, dynamic>? audioStream;
    for (final stream in streams) {
      final type = stream['codec_type'] as String?;
      if (type == 'video' && videoStream == null) {
        // Cover art is stored as a video stream with an attached_pic
        // disposition; treating it as picture makes an MP3 look like a video.
        final disposition =
            (stream['disposition'] as Map?)?.cast<String, dynamic>();
        if ((disposition?['attached_pic'] as num?)?.toInt() == 1) continue;
        videoStream = stream;
      } else if (type == 'audio' && audioStream == null) {
        audioStream = stream;
      }
    }

    // Prefer the container duration; fall back to the video stream's, which
    // some MKV/AVI files carry instead.
    final durationSeconds = _parseDouble(format['duration']) ??
        _parseDouble(videoStream?['duration']) ??
        _parseDouble(audioStream?['duration']) ??
        0.0;

    final kind = videoStream != null
        ? (kindGuess == AssetKind.image ? AssetKind.image : AssetKind.video)
        : (audioStream != null ? AssetKind.audio : kindGuess);

    return MediaAsset(
      id: assetId,
      path: path,
      kind: kind,
      duration: kind == AssetKind.image
          ? Duration.zero
          : Duration(microseconds: (durationSeconds * 1e6).round()),
      width: (videoStream?['width'] as num?)?.toInt() ?? 0,
      height: (videoStream?['height'] as num?)?.toInt() ?? 0,
      fps: _parseFrameRate(videoStream?['r_frame_rate'] as String?),
      videoCodec: videoStream?['codec_name'] as String?,
      audioCodec: audioStream?['codec_name'] as String?,
      bitrate: int.tryParse('${format['bit_rate'] ?? ''}') ?? 0,
      audioSampleRate: int.tryParse('${audioStream?['sample_rate'] ?? ''}') ?? 0,
      audioChannels: (audioStream?['channels'] as num?)?.toInt() ?? 0,
      rotationDegrees: _parseRotation(videoStream),
      fileSizeBytes: fileSize,
      hasAudioStream: audioStream != null,
      hasVideoStream: videoStream != null,
      displayName: FileUtils.baseNameWithoutExtension(path),
      importedAt: DateTime.now(),
    );
  }

  /// `r_frame_rate` arrives as a rational string like `30000/1001`.
  static double _parseFrameRate(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final parts = raw.split('/');
    if (parts.length != 2) return double.tryParse(raw) ?? 0;
    final numerator = double.tryParse(parts[0]) ?? 0;
    final denominator = double.tryParse(parts[1]) ?? 0;
    if (denominator == 0) return 0;
    return numerator / denominator;
  }

  /// Rotation lives in two different places depending on the muxer: modern
  /// files use display-matrix side data, older ones a `rotate` tag.
  static int _parseRotation(Map<String, dynamic>? videoStream) {
    if (videoStream == null) return 0;

    final sideData = (videoStream['side_data_list'] as List?) ?? const [];
    for (final entry in sideData) {
      final map = (entry as Map).cast<String, dynamic>();
      final rotation = _parseDouble(map['rotation']);
      if (rotation != null) return _normaliseRotation(rotation.round());
    }

    final tags = (videoStream['tags'] as Map?)?.cast<String, dynamic>();
    final tagged = int.tryParse('${tags?['rotate'] ?? ''}');
    if (tagged != null) return _normaliseRotation(tagged);

    return 0;
  }

  /// The display matrix reports counter-clockwise negatives (`-90`); the rest
  /// of the app works in clockwise 0/90/180/270.
  static int _normaliseRotation(int degrees) {
    final normalised = ((degrees % 360) + 360) % 360;
    return switch (normalised) {
      90 || 180 || 270 => normalised,
      _ => 0,
    };
  }

  static double? _parseDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
