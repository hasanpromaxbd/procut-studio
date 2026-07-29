/// Contract for importing and inspecting media.
library;

import 'dart:typed_data';

import '../../core/error/result.dart';
import '../entities/media_asset.dart';

abstract interface class MediaRepository {
  /// Probes [path] and returns an asset describing it. Fails with
  /// `UnsupportedMediaFailure` when the file is not decodable.
  Future<Result<MediaAsset>> importFile(String path, {bool copyIntoApp = false});

  Future<Result<List<MediaAsset>>> importFiles(
    List<String> paths, {
    bool copyIntoApp = false,
  });

  /// A single frame as JPEG bytes, cached on disk.
  Future<Result<Uint8List>> thumbnail(
    MediaAsset asset,
    Duration at, {
    int width = 96,
  });

  /// Peak amplitudes normalised to 0..1, one entry per
  /// `AppConstants.waveformSamplesPerSecond`.
  Future<Result<Float32List>> waveform(MediaAsset asset);

  /// Builds a low-resolution proxy so scrubbing 4K footage stays responsive.
  /// Returns the asset updated with `proxyPath`.
  Future<Result<MediaAsset>> generateProxy(
    MediaAsset asset, {
    int targetHeight = 540,
  });

  /// Detects beats for music-driven editing. Returns timestamps.
  Future<Result<List<Duration>>> detectBeats(MediaAsset asset);

  /// Frees cached derivatives (thumbnails, waveforms, proxies).
  Future<Result<void>> clearDerivedCache();

  Future<Result<int>> cacheSizeBytes();
}
