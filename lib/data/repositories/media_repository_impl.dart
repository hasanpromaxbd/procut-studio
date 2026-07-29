/// [MediaRepository] backed by FFprobe/FFmpeg with a Hive metadata cache.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/file_utils.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/repositories/media_repository.dart';
import '../../engine/audio/waveform_service.dart';
import '../../engine/ffmpeg/ffmpeg_service.dart';
import '../../engine/ffmpeg/ffprobe_service.dart';
import '../../engine/render/thumbnail_cache.dart';
import '../datasources/local/hive_store.dart';

class MediaRepositoryImpl implements MediaRepository {
  MediaRepositoryImpl({
    required FFprobeService probe,
    required FFmpegService ffmpeg,
    required PathService paths,
    required HiveStore store,
    required WaveformService waveforms,
    required ThumbnailCache thumbnails,
  }) : _probe = probe,
       _ffmpeg = ffmpeg,
       _paths = paths,
       _store = store,
       _waveforms = waveforms,
       _thumbnails = thumbnails;

  static const _log = Log('MediaRepository');

  final FFprobeService _probe;
  final FFmpegService _ffmpeg;
  final PathService _paths;
  final HiveStore _store;
  final WaveformService _waveforms;
  final ThumbnailCache _thumbnails;

  @override
  Future<Result<MediaAsset>> importFile(
    String path, {
    bool copyIntoApp = false,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return Result.err(
        UnsupportedMediaFailure('That file no longer exists.', path: path),
      );
    }

    // Content key: path + size + mtime. Re-importing the same untouched file
    // reuses its asset id, and therefore its thumbnails, waveform and proxy.
    final stat = await file.stat();
    final cacheKey = _cacheKey(path, stat.size, stat.modified);
    final cached = _store.mediaMeta.get(cacheKey);
    if (cached != null) {
      try {
        final asset = MediaAsset.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
        if (await File(asset.path).exists()) {
          _log.d('import cache hit', fields: {'id': asset.id});
          return Result.ok(asset);
        }
      } catch (_) {
        await _store.mediaMeta.delete(cacheKey);
      }
    }

    var workingPath = path;
    if (copyIntoApp) {
      final copied = await FileUtils.copyInto(file, _paths.mediaDir);
      workingPath = copied.path;
    }

    final probed = await _probe.probe(workingPath, assetId: IdGenerator.asset());
    if (probed.isErr) return probed;

    final asset = probed.valueOrNull!;
    if (asset.kind != AssetKind.image && asset.duration <= Duration.zero) {
      return Result.err(
        UnsupportedMediaFailure(
          'That file has no readable duration and cannot be edited.',
          path: workingPath,
        ),
      );
    }

    await _store.mediaMeta.put(cacheKey, jsonEncode(asset.toJson()));
    _log.i('imported', fields: {'id': asset.id, 'kind': asset.kind.id});
    return Result.ok(asset);
  }

  @override
  Future<Result<List<MediaAsset>>> importFiles(
    List<String> paths, {
    bool copyIntoApp = false,
  }) async {
    final assets = <MediaAsset>[];
    final failures = <Failure>[];
    for (final path in paths) {
      final result = await importFile(path, copyIntoApp: copyIntoApp);
      result.fold(assets.add, failures.add);
    }
    // A partial import beats an all-or-nothing failure: the user picked ten
    // clips and one is a corrupt download.
    if (assets.isEmpty && failures.isNotEmpty) {
      return Result.err(failures.first);
    }
    return Result.ok(assets);
  }

  @override
  Future<Result<Uint8List>> thumbnail(
    MediaAsset asset,
    Duration at, {
    int width = 96,
  }) async {
    final key = ThumbnailCache.keyFor(asset, at, width: width);
    final file = _paths.thumbnailFile(key.assetId, key.timeMs, key.width);
    final image = await _thumbnails.request(asset, key);
    if (image == null || !await file.exists()) {
      return const Result.err(
        MediaProcessingFailure('Could not read a frame from that clip.'),
      );
    }
    return Result.ok(await file.readAsBytes());
  }

  @override
  Future<Result<Float32List>> waveform(MediaAsset asset) =>
      _waveforms.extract(asset);

  @override
  Future<Result<List<Duration>>> detectBeats(MediaAsset asset) =>
      _waveforms.detectBeats(asset);

  @override
  Future<Result<MediaAsset>> generateProxy(
    MediaAsset asset, {
    int targetHeight = 540,
  }) async {
    if (asset.kind != AssetKind.video) return Result.ok(asset);

    final target = _paths.proxyFile(asset.id, targetHeight);
    if (await target.exists()) {
      return Result.ok(asset.copyWith(proxyPath: target.path));
    }
    await target.parent.create(recursive: true);

    // A proxy exists purely so scrubbing is smooth: `ultrafast` + a high CRF
    // keeps generation quick, and the file is never used for export.
    final command = [
      '-y', '-hide_banner',
      '-i', _quote(asset.path),
      '-vf', 'scale=-2:$targetHeight:flags=fast_bilinear',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '28',
      '-pix_fmt', 'yuv420p',
      '-g', '15', // dense keyframes → fast seeking, which is the whole point
      '-an',
      _quote(target.path),
    ].join(' ');

    final result = await _ffmpeg.run(command, totalDuration: asset.duration);
    if (result.isErr) return Result.err(result.failureOrNull!);

    final updated = asset.copyWith(proxyPath: target.path);
    _log.i('proxy built', fields: {'id': asset.id, 'height': targetHeight});
    return Result.ok(updated);
  }

  @override
  Future<Result<void>> clearDerivedCache() async => guard(() async {
    _thumbnails.clear();
    await _paths.clearCaches();
  }, onError: (e, s) => StorageFailure(
        'Could not clear the cache.',
        cause: e,
        stackTrace: s,
      ));

  @override
  Future<Result<int>> cacheSizeBytes() async => guard(
    _paths.cacheSizeBytes,
    onError: (e, s) => StorageFailure(
      'Could not measure the cache.',
      cause: e,
      stackTrace: s,
    ),
  );

  static String _cacheKey(String path, int size, DateTime modified) =>
      '$path|$size|${modified.millisecondsSinceEpoch}';

  static String _quote(String value) =>
      value.contains(' ') ? '"$value"' : value;
}
