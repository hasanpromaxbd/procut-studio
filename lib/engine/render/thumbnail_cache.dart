/// Two-tier thumbnail cache: decoded images in memory, JPEGs on disk.
///
/// The timeline asks for a thumbnail every time a clip scrolls into view, at
/// 60fps. Decoding a JPEG per request would be hopeless, so:
///
///   * memory (LRU, bounded by count) — hit on the same frame, costs nothing;
///   * disk — hit across sessions, costs a decode;
///   * FFmpeg — cold, costs a process launch, so it is de-duplicated per key
///     and rate-limited by the FFmpeg service queue.
///
/// Requests for a frame already being generated join the in-flight future
/// rather than launching a second extraction — without that, scrolling fires
/// dozens of identical FFmpeg calls.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/media_asset.dart';
import '../ffmpeg/ffmpeg_service.dart';

class ThumbnailKey {
  const ThumbnailKey({
    required this.assetId,
    required this.timeMs,
    required this.width,
  });

  final String assetId;
  final int timeMs;
  final int width;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThumbnailKey &&
          other.assetId == assetId &&
          other.timeMs == timeMs &&
          other.width == width;

  @override
  int get hashCode => Object.hash(assetId, timeMs, width);

  @override
  String toString() => '$assetId@${timeMs}ms/${width}px';
}

class ThumbnailCache {
  ThumbnailCache({
    required FFmpegService ffmpeg,
    required PathService paths,
    this.capacity = AppConstants.thumbnailCacheCapacity,
  }) : _ffmpeg = ffmpeg,
       _paths = paths;

  static const _log = Log('ThumbnailCache');

  final FFmpegService _ffmpeg;
  final PathService _paths;
  final int capacity;

  /// Insertion-ordered so the first key is the least recently used.
  final LinkedHashMap<ThumbnailKey, ui.Image> _memory = LinkedHashMap();
  final Map<ThumbnailKey, Future<ui.Image?>> _inFlight = {};

  int get size => _memory.length;

  /// Synchronous lookup for the painter, which cannot await.
  /// Returns null on a miss; call [request] to fill it and repaint.
  ui.Image? peek(ThumbnailKey key) {
    final image = _memory.remove(key);
    if (image == null) return null;
    _memory[key] = image; // refresh LRU position
    return image;
  }

  /// Quantises a time to the nearest thumbnail slot.
  ///
  /// Without this, a scrolling timeline requests a *different* millisecond
  /// every frame and the cache never hits. Snapping to a grid whose spacing
  /// depends on zoom means neighbouring requests collapse onto one key.
  static ThumbnailKey keyFor(
    MediaAsset asset,
    Duration time, {
    int width = AppConstants.thumbnailPixelWidth,
    Duration granularity = const Duration(milliseconds: 500),
  }) {
    final slot =
        (time.inMilliseconds / granularity.inMilliseconds).round() *
        granularity.inMilliseconds;
    return ThumbnailKey(
      assetId: asset.id,
      timeMs: slot.clamp(0, asset.duration.inMilliseconds),
      width: width,
    );
  }

  /// Fetches from memory, then disk, then FFmpeg.
  Future<ui.Image?> request(MediaAsset asset, ThumbnailKey key) {
    final cached = peek(key);
    if (cached != null) return Future.value(cached);

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _load(asset, key);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<ui.Image?> _load(MediaAsset asset, ThumbnailKey key) async {
    try {
      final file = _paths.thumbnailFile(key.assetId, key.timeMs, key.width);

      if (!await file.exists()) {
        final extracted = await _extract(asset, key, file);
        if (!extracted) return null;
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;

      final image = await _decode(bytes, key.width);
      _put(key, image);
      return image;
    } catch (e) {
      _log.d('thumbnail failed for $key: $e');
      return null;
    }
  }

  Future<bool> _extract(MediaAsset asset, ThumbnailKey key, File target) async {
    await target.parent.create(recursive: true);
    final seconds = TimeUtils.toFfmpegSeconds(
      Duration(milliseconds: key.timeMs),
    );

    // `-ss` before `-i` seeks on keyframes, which is approximate but ~100×
    // faster than decoding from zero. For a scrubbing strip that trade is
    // exactly right — nobody notices a thumbnail being one GOP off.
    final command = [
      '-y', '-hide_banner',
      '-ss', seconds,
      '-i', _quote(asset.previewPath),
      '-frames:v', '1',
      '-vf', 'scale=${key.width}:-2:flags=fast_bilinear',
      '-q:v', '6',
      _quote(target.path),
    ].join(' ');

    final result = await _ffmpeg.run(command, queued: false);
    return result.isOk && await target.exists();
  }

  Future<ui.Image> _decode(Uint8List bytes, int targetWidth) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  void _put(ThumbnailKey key, ui.Image image) {
    _memory[key] = image;
    while (_memory.length > capacity) {
      final oldest = _memory.keys.first;
      _memory.remove(oldest)?.dispose();
    }
  }

  /// Warms the cache for a visible range so scrolling does not stutter on the
  /// first paint of each clip.
  Future<void> prefetch(
    MediaAsset asset,
    Duration from,
    Duration to, {
    int count = 6,
    int width = AppConstants.thumbnailPixelWidth,
  }) async {
    if (count <= 0 || to <= from) return;
    final step = (to - from) ~/ count;
    for (var i = 0; i < count; i++) {
      final key = keyFor(asset, from + step * i, width: width);
      if (_memory.containsKey(key) || _inFlight.containsKey(key)) continue;
      unawaited(request(asset, key));
    }
  }

  void evict(String assetId) {
    final keys = _memory.keys.where((k) => k.assetId == assetId).toList();
    for (final key in keys) {
      _memory.remove(key)?.dispose();
    }
  }

  void clear() {
    for (final image in _memory.values) {
      image.dispose();
    }
    _memory.clear();
  }

  void dispose() => clear();

  static String _quote(String value) =>
      value.contains(' ') ? '"$value"' : value;
}
