/// [AssetLibraryRepository] over a bundled manifest plus an optional remote
/// catalogue.
///
/// The bundled set always works offline. Remote items are merged in when the
/// network is reachable, and a failure there is *not* an error — browsing
/// falls back to what ships in the APK rather than showing an empty screen on
/// a train.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../domain/repositories/asset_library_repository.dart';
import '../datasources/local/hive_store.dart';
import '../datasources/remote/asset_catalog_api.dart';

class AssetLibraryRepositoryImpl implements AssetLibraryRepository {
  AssetLibraryRepositoryImpl({
    required PathService paths,
    required HiveStore store,
    AssetCatalogApi? api,
  }) : _paths = paths,
       _store = store,
       _api = api;

  static const _log = Log('AssetLibrary');
  static const String _bundledManifest = 'assets/data/library_manifest.json';

  final PathService _paths;
  final HiveStore _store;
  final AssetCatalogApi? _api;

  List<LibraryItem>? _bundled;

  Future<List<LibraryItem>> _loadBundled() async {
    if (_bundled != null) return _bundled!;
    try {
      final raw = await rootBundle.loadString(_bundledManifest);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final items = ((json['items'] as List?) ?? const [])
          .map((e) => LibraryItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      _log.i('bundled catalogue loaded', fields: {'count': items.length});
      return _bundled = items;
    } catch (e) {
      _log.w('bundled catalogue unreadable', error: e);
      return _bundled = const [];
    }
  }

  @override
  Future<Result<List<LibraryItem>>> browse(
    LibraryCategory category, {
    String? collection,
    String? query,
  }) async {
    final items = <String, LibraryItem>{
      for (final item in await _loadBundled())
        if (item.category == category) item.id: item,
    };

    final api = _api;
    if (api != null) {
      final remote = await api.fetchCatalog(category);
      remote.fold(
        (fetched) {
          for (final item in fetched) {
            // Bundled entries win on id collision — they are guaranteed
            // present, the remote copy may not be.
            items.putIfAbsent(item.id, () => item);
          }
        },
        (failure) => _log.d('remote catalogue unavailable: ${failure.message}'),
      );
    }

    // Reattach any local downloads so the UI shows them as ready.
    final resolved = items.values.map((item) {
      final localPath = _store.settings.get(_downloadKey(item.id));
      return localPath == null ? item : item.copyWith(localPath: localPath);
    });

    var filtered = resolved.toList();
    if (collection != null && collection.isNotEmpty) {
      filtered = filtered.where((i) => i.collection == collection).toList();
    }
    if (query != null && query.trim().isNotEmpty) {
      final needle = query.toLowerCase().trim();
      filtered = filtered
          .where(
            (i) =>
                i.name.toLowerCase().contains(needle) ||
                i.collection.toLowerCase().contains(needle) ||
                i.tags.any((t) => t.toLowerCase().contains(needle)),
          )
          .toList();
    }

    filtered.sort((a, b) {
      final byCollection = a.collection.compareTo(b.collection);
      return byCollection != 0 ? byCollection : a.name.compareTo(b.name);
    });
    return Result.ok(filtered);
  }

  @override
  Future<Result<List<String>>> collections(LibraryCategory category) async {
    final browsed = await browse(category);
    return browsed.map(
      (items) => items
          .map((i) => i.collection)
          .where((c) => c.isNotEmpty)
          .toSet()
          .toList()
        ..sort(),
    );
  }

  @override
  Future<Result<LibraryItem>> materialise(
    LibraryItem item, {
    void Function(double progress)? onProgress,
  }) async {
    if (item.isDownloaded && await File(item.localPath!).exists()) {
      return Result.ok(item);
    }

    final targetDir = Directory(
      p.join(_paths.mediaDir.path, 'library', item.category.name),
    );
    await targetDir.create(recursive: true);

    // Bundled: copy out of the APK so FFmpeg can open it by path — the
    // encoder cannot read `asset:` URIs.
    if (item.isBundled) {
      return guard(() async {
        final data = await rootBundle.load(item.bundledAssetPath!);
        final target = File(
          p.join(targetDir.path, '${item.id}${p.extension(item.bundledAssetPath!)}'),
        );
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await _store.settings.put(_downloadKey(item.id), target.path);
        onProgress?.call(1);
        return item.copyWith(localPath: target.path);
      }, onError: (e, s) => StorageFailure(
            'Could not unpack "${item.name}".',
            cause: e,
            stackTrace: s,
          ));
    }

    final api = _api;
    if (api == null || item.remoteUrl == null) {
      return Result.err(
        FeatureUnavailableFailure(
          '"${item.name}" is not available offline.',
          feature: 'asset_download',
        ),
      );
    }

    final target = File(
      p.join(targetDir.path, '${item.id}${p.extension(item.remoteUrl!)}'),
    );
    final downloaded = await api.download(
      item.remoteUrl!,
      target.path,
      onProgress: onProgress,
    );
    if (downloaded.isErr) return Result.err(downloaded.failureOrNull!);

    await _store.settings.put(_downloadKey(item.id), target.path);
    _log.i('downloaded', fields: {'id': item.id});
    return Result.ok(item.copyWith(localPath: target.path));
  }

  @override
  Future<Result<void>> removeDownload(String itemId) async => guard(() async {
    final path = _store.settings.get(_downloadKey(itemId));
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await _store.settings.delete(_downloadKey(itemId));
  }, onError: (e, s) => StorageFailure(
        'Could not remove that download.',
        cause: e,
        stackTrace: s,
      ));

  @override
  Future<Result<List<String>>> fontFamilies({String? query}) async {
    // GoogleFonts ships a manifest of ~1500 families, which is where the
    // "300+ fonts" requirement is actually satisfied. Families are fetched and
    // cached on first use, so this list is available offline but individual
    // faces need one download each.
    final all = GoogleFonts.asMap().keys.toList()..sort();
    if (query == null || query.trim().isEmpty) return Result.ok(all);
    final needle = query.toLowerCase().trim();
    return Result.ok(
      all.where((f) => f.toLowerCase().contains(needle)).toList(),
    );
  }

  static String _downloadKey(String itemId) => 'library.download.$itemId';
}

/// Dio-backed catalogue client.
class DioAssetCatalogApi implements AssetCatalogApi {
  DioAssetCatalogApi({required Dio dio, required this.baseUrl}) : _dio = dio;

  static const _log = Log('AssetCatalogApi');

  final Dio _dio;
  final String baseUrl;

  @override
  Future<Result<List<LibraryItem>>> fetchCatalog(
    LibraryCategory category,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/catalog/${category.name}',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final items = ((response.data?['items'] as List?) ?? const [])
          .map((e) => LibraryItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      return Result.ok(items);
    } on DioException catch (e) {
      _log.d('catalogue fetch failed: ${e.type}');
      return Result.err(
        NetworkFailure(
          'Could not reach the asset library.',
          statusCode: e.response?.statusCode,
          cause: e,
        ),
      );
    }
  }

  @override
  Future<Result<void>> download(
    String url,
    String targetPath, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      // Download beside the target and rename on success, so a cancelled or
      // failed transfer never leaves a truncated file that looks valid.
      final tempPath = '$targetPath.part';
      await _dio.download(
        url,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
      await File(tempPath).rename(targetPath);
      return const Result.ok(null);
    } on DioException catch (e) {
      return Result.err(
        NetworkFailure(
          'Download failed.',
          statusCode: e.response?.statusCode,
          cause: e,
        ),
      );
    } catch (e, s) {
      return Result.err(
        StorageFailure('Could not save the download.', cause: e, stackTrace: s),
      );
    }
  }
}
