/// Composition root.
///
/// Every dependency is declared once here and injected through Riverpod. No
/// class reaches for a singleton; anything a test wants to fake is an override
/// on `ProviderScope`. The infrastructure providers throw until [bootstrap]
/// has run, which is deliberate — an un-awaited `PathService` used to be a
/// class of bug that only appeared on cold start.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/local/hive_store.dart';
import '../../data/datasources/remote/asset_catalog_api.dart';
import '../../data/repositories/asset_library_repository_impl.dart';
import '../../data/repositories/media_repository_impl.dart';
import '../../data/repositories/project_repository_impl.dart';
import '../../domain/repositories/ai_repository.dart';
import '../../domain/repositories/asset_library_repository.dart';
import '../../domain/repositories/export_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/repositories/project_repository.dart';
import '../../engine/ai/ai_service.dart';
import '../../engine/audio/waveform_service.dart';
import '../../engine/export/export_engine.dart';
import '../../engine/ffmpeg/ffmpeg_service.dart';
import '../../engine/ffmpeg/ffprobe_service.dart';
import '../../engine/ffmpeg/hardware_encoder.dart';
import '../../engine/render/layer_rasteriser.dart';
import '../../engine/render/shader_library.dart';
import '../../engine/render/thumbnail_cache.dart';
import '../services/path_service.dart';
import '../services/permission_service.dart';

// ── Infrastructure (overridden in bootstrap) ──────────────────────────

/// Filesystem locations. Overridden with an initialised instance at startup.
final pathServiceProvider = Provider<PathService>(
  (ref) => throw StateError('pathServiceProvider must be overridden in main()'),
);

/// Hive boxes. Overridden with an opened instance at startup.
final hiveStoreProvider = Provider<HiveStore>(
  (ref) => throw StateError('hiveStoreProvider must be overridden in main()'),
);

/// Compiled fragment shaders. Overridden with a warmed instance at startup.
final shaderLibraryProvider = Provider<ShaderLibrary>(
  (ref) => throw StateError('shaderLibraryProvider must be overridden in main()'),
);

// ── Engine ────────────────────────────────────────────────────────────

final ffmpegServiceProvider = Provider<FFmpegService>((ref) {
  final service = FFmpegService();
  ref.onDispose(service.cancelAll);
  return service;
});

final ffprobeServiceProvider = Provider<FFprobeService>(
  (ref) => FFprobeService(),
);

final hardwareEncoderProbeProvider = Provider<HardwareEncoderProbe>(
  (ref) => HardwareEncoderProbe(ref.watch(ffmpegServiceProvider)),
);

final thumbnailCacheProvider = Provider<ThumbnailCache>((ref) {
  final cache = ThumbnailCache(
    ffmpeg: ref.watch(ffmpegServiceProvider),
    paths: ref.watch(pathServiceProvider),
  );
  ref.onDispose(cache.dispose);
  return cache;
});

final waveformServiceProvider = Provider<WaveformService>(
  (ref) => WaveformService(
    ffmpeg: ref.watch(ffmpegServiceProvider),
    paths: ref.watch(pathServiceProvider),
  ),
);

final layerRasteriserProvider = Provider<LayerRasteriser>(
  (ref) => const LayerRasteriser(),
);

final permissionServiceProvider = Provider<PermissionService>(
  (ref) => PermissionService(),
);

// ── Networking ────────────────────────────────────────────────────────

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'User-Agent': 'ProCutStudio/1.0'},
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});

/// Base URL for the optional remote asset catalogue. Null disables it and the
/// library falls back to bundled content only.
final assetCatalogBaseUrlProvider = Provider<String?>((ref) => null);

final assetCatalogApiProvider = Provider<AssetCatalogApi?>((ref) {
  final baseUrl = ref.watch(assetCatalogBaseUrlProvider);
  if (baseUrl == null || baseUrl.isEmpty) return null;
  return DioAssetCatalogApi(dio: ref.watch(dioProvider), baseUrl: baseUrl);
});

/// Optional inference backend for the model-driven AI features.
final aiBackendProvider = Provider<AiBackend?>((ref) => null);

// ── Repositories ──────────────────────────────────────────────────────

final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  final repository = ProjectRepositoryImpl(
    store: ref.watch(hiveStoreProvider),
    paths: ref.watch(pathServiceProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => MediaRepositoryImpl(
    probe: ref.watch(ffprobeServiceProvider),
    ffmpeg: ref.watch(ffmpegServiceProvider),
    paths: ref.watch(pathServiceProvider),
    store: ref.watch(hiveStoreProvider),
    waveforms: ref.watch(waveformServiceProvider),
    thumbnails: ref.watch(thumbnailCacheProvider),
  ),
);

final assetLibraryRepositoryProvider = Provider<AssetLibraryRepository>(
  (ref) => AssetLibraryRepositoryImpl(
    paths: ref.watch(pathServiceProvider),
    store: ref.watch(hiveStoreProvider),
    api: ref.watch(assetCatalogApiProvider),
  ),
);

final exportRepositoryProvider = Provider<ExportRepository>(
  (ref) => ExportEngine(
    ffmpeg: ref.watch(ffmpegServiceProvider),
    paths: ref.watch(pathServiceProvider),
    encoderProbe: ref.watch(hardwareEncoderProbeProvider),
    rasteriser: ref.watch(layerRasteriserProvider),
  ),
);

final aiRepositoryProvider = Provider<AiRepository>(
  (ref) => AiService(
    ffmpeg: ref.watch(ffmpegServiceProvider),
    paths: ref.watch(pathServiceProvider),
    backend: ref.watch(aiBackendProvider),
  ),
);

/// Capabilities that will actually work right now — drives whether an AI tool
/// is offered or shown with a "needs setup" badge.
final aiCapabilitiesProvider = FutureProvider<Set<AiCapability>>(
  (ref) => ref.watch(aiRepositoryProvider).availableCapabilities(),
);
