/// Hive-backed [ProjectRepository].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/file_utils.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/project.dart';
import '../../domain/repositories/project_repository.dart';
import '../datasources/local/hive_store.dart';
import '../datasources/local/project_migrations.dart';

class ProjectRepositoryImpl implements ProjectRepository {
  ProjectRepositoryImpl({required HiveStore store, required PathService paths})
    : _store = store,
      _paths = paths;

  static const _log = Log('ProjectRepository');

  final HiveStore _store;
  final PathService _paths;

  final StreamController<List<ProjectSummary>> _summaries =
      StreamController<List<ProjectSummary>>.broadcast();

  @override
  Future<Result<List<ProjectSummary>>> listSummaries() async => guard(() async {
    final summaries = <ProjectSummary>[];
    for (final key in _store.projects.keys) {
      final raw = _store.projects.get(key);
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        summaries.add(ProjectSummary.fromJson(json));
      } catch (e) {
        // One unreadable project must not hide every other project on the
        // home screen.
        _log.w('skipping unreadable project $key', error: e);
      }
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }, onError: (e, s) => StorageFailure(
        'Could not read your projects.',
        cause: e,
        stackTrace: s,
      ));

  @override
  Stream<List<ProjectSummary>> watchSummaries() {
    // Prime the stream so a new listener does not stare at a spinner until the
    // next write happens.
    unawaited(_emitSummaries());
    return _summaries.stream;
  }

  Future<void> _emitSummaries() async {
    if (_summaries.isClosed) return;
    final result = await listSummaries();
    result.fold(_summaries.add, (failure) => _log.w(failure.message));
  }

  @override
  Future<Result<Project>> load(String projectId) async {
    final raw = _store.projects.get(projectId);
    if (raw == null) {
      return Result.err(
        ProjectCorruptFailure('That project no longer exists.', projectId: projectId),
      );
    }
    return _decode(raw, projectId);
  }

  Result<Project> _decode(String raw, String projectId) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final migrated = ProjectMigrations.migrate(json);
      return migrated.map(Project.fromJson);
    } catch (e, s) {
      _log.e('decode failed', error: e, stackTrace: s, fields: {'id': projectId});
      return Result.err(
        ProjectCorruptFailure(
          'That project file is damaged. Try restoring a backup.',
          projectId: projectId,
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  @override
  Future<Result<void>> save(Project project) async => guard(() async {
    final pruned = project.pruneAssets().copyWith(
      updatedAt: DateTime.now(),
      schemaVersion: AppConstants.projectSchemaVersion,
    );
    final encoded = jsonEncode(pruned.toJson());

    // Rotate a backup *before* overwriting, so the previous good state
    // survives a crash mid-write.
    await _rotateBackup(project.id);
    await _store.projects.put(project.id, encoded);

    _log.d(
      'saved',
      fields: {'id': project.id, 'bytes': encoded.length, 'clips': pruned.clipCount},
    );
    unawaited(_emitSummaries());
  }, onError: (e, s) => StorageFailure(
        'Could not save the project.',
        cause: e,
        stackTrace: s,
      ));

  Future<void> _rotateBackup(String projectId) async {
    final current = _store.projects.get(projectId);
    if (current == null) return;
    try {
      await _paths.backupsDir.create(recursive: true);
      // Shuffle N-1 → N so index 0 is always the most recent previous save.
      for (var i = AppConstants.projectBackupCount - 1; i > 0; i--) {
        final from = _paths.projectBackupFile(projectId, i - 1);
        if (await from.exists()) {
          await from.copy(_paths.projectBackupFile(projectId, i).path);
        }
      }
      await FileUtils.writeAtomically(
        _paths.projectBackupFile(projectId, 0),
        current,
      );
    } catch (e) {
      // A failed backup must never block a save.
      _log.w('backup rotation failed', error: e);
    }
  }

  @override
  Future<Result<void>> delete(String projectId) async => guard(() async {
    await _store.projects.delete(projectId);
    await _store.recents.delete(projectId);
    for (var i = 0; i < AppConstants.projectBackupCount; i++) {
      await FileUtils.deleteQuietly(_paths.projectBackupFile(projectId, i).path);
    }
    _log.i('deleted', fields: {'id': projectId});
    unawaited(_emitSummaries());
  }, onError: (e, s) => StorageFailure(
        'Could not delete the project.',
        cause: e,
        stackTrace: s,
      ));

  @override
  Future<Result<Project>> duplicate(String projectId, {String? newName}) async {
    final loaded = await load(projectId);
    if (loaded.isErr) return loaded;
    final original = loaded.valueOrNull!;

    final copy = original.copyWith(
      id: IdGenerator.project(),
      name: newName ?? '${original.name} copy',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final saved = await save(copy);
    if (saved.isErr) return Result.err(saved.failureOrNull!);
    return Result.ok(copy);
  }

  @override
  Future<Result<void>> rename(String projectId, String name) async {
    final loaded = await load(projectId);
    if (loaded.isErr) return Result.err(loaded.failureOrNull!);
    return save(loaded.valueOrNull!.copyWith(name: name));
  }

  // ── Bundles ──────────────────────────────────────────────────────────

  @override
  Future<Result<String>> exportBundle(
    String projectId, {
    String? destination,
  }) async {
    final loaded = await load(projectId);
    if (loaded.isErr) return Result.err(loaded.failureOrNull!);
    final project = loaded.valueOrNull!;

    return guard(() async {
      final archive = Archive();

      // Media is stored under `media/<assetId><ext>` and the manifest is
      // rewritten to match, so the bundle is self-contained and relocatable.
      final rehomed = <String, MediaAsset>{};
      for (final asset in project.assets.values) {
        final file = File(asset.path);
        if (!await file.exists()) {
          _log.w('bundle skipping missing asset', fields: {'id': asset.id});
          continue;
        }
        final ext = p.extension(asset.path);
        final archivePath = 'media/${asset.id}$ext';
        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
        rehomed[asset.id] = asset.copyWith(path: archivePath, proxyPath: '');
      }

      final manifest = utf8.encode(
        jsonEncode(project.copyWith(assets: rehomed).toJson()),
      );
      archive.addFile(
        ArchiveFile('project.json', manifest.length, manifest),
      );

      final encoded = ZipEncoder().encode(archive);

      final safeName = PathService.sanitiseFileName(project.name);
      final outPath = destination ??
          p.join(
            _paths.exportsDir.path,
            '$safeName.${AppConstants.projectBundleExtension}',
          );
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(encoded, flush: true);

      _log.i('bundle written', fields: {'path': outPath, 'bytes': encoded.length});
      return outPath;
    }, onError: (e, s) => StorageFailure(
          'Could not export the project bundle.',
          cause: e,
          stackTrace: s,
        ));
  }

  @override
  Future<Result<Project>> importBundle(String bundlePath) async => guard(
    () async {
      final bytes = await File(bundlePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final manifestFile = archive.files.firstWhere(
        (f) => f.name == 'project.json',
        orElse: () => throw const FormatException('No project.json in bundle'),
      );
      final manifest =
          jsonDecode(utf8.decode(manifestFile.content as List<int>))
              as Map<String, dynamic>;

      final migrated = ProjectMigrations.migrate(manifest);
      if (migrated.isErr) throw StateError(migrated.failureOrNull!.message);
      var project = Project.fromJson(migrated.valueOrNull!);

      // Fresh id so importing a bundle twice does not overwrite the first.
      final newId = IdGenerator.project();
      final mediaDir = Directory(p.join(_paths.mediaDir.path, newId));
      await mediaDir.create(recursive: true);

      final rehomed = <String, MediaAsset>{};
      for (final asset in project.assets.values) {
        final entry = archive.files.where((f) => f.name == asset.path).firstOrNull;
        if (entry == null) {
          _log.w('bundle missing media', fields: {'id': asset.id});
          continue;
        }
        final target = File(p.join(mediaDir.path, p.basename(asset.path)));
        await target.writeAsBytes(entry.content as List<int>, flush: true);
        rehomed[asset.id] = asset.copyWith(path: target.path, proxyPath: '');
      }

      project = project.copyWith(
        id: newId,
        assets: rehomed,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final saved = await save(project);
      if (saved.isErr) throw StateError(saved.failureOrNull!.message);

      _log.i('bundle imported', fields: {'id': newId, 'assets': rehomed.length});
      return project;
    },
    onError: (e, s) => StorageFailure(
      'That file is not a valid ProCut project bundle.',
      cause: e,
      stackTrace: s,
    ),
  );

  // ── Backups ──────────────────────────────────────────────────────────

  @override
  Future<Result<List<DateTime>>> listBackups(String projectId) async => guard(
    () async {
      final stamps = <DateTime>[];
      for (var i = 0; i < AppConstants.projectBackupCount; i++) {
        final file = _paths.projectBackupFile(projectId, i);
        if (await file.exists()) {
          stamps.add((await file.stat()).modified);
        }
      }
      return stamps;
    },
    onError: (e, s) => StorageFailure('Could not list backups.', cause: e, stackTrace: s),
  );

  @override
  Future<Result<Project>> restoreBackup(String projectId, int backupIndex) async {
    final file = _paths.projectBackupFile(projectId, backupIndex);
    if (!await file.exists()) {
      return const Result.err(StorageFailure('That backup no longer exists.'));
    }
    final raw = await file.readAsString();
    final decoded = _decode(raw, projectId);
    if (decoded.isErr) return decoded;

    final project = decoded.valueOrNull!;
    final saved = await save(project);
    if (saved.isErr) return Result.err(saved.failureOrNull!);
    _log.i('restored backup', fields: {'id': projectId, 'index': backupIndex});
    return Result.ok(project);
  }

  // ── Recents ──────────────────────────────────────────────────────────

  @override
  Future<Result<List<String>>> recentProjectIds({int limit = 10}) async =>
      guard(() async {
        final entries = <MapEntry<String, int>>[];
        for (final key in _store.recents.keys) {
          final value = int.tryParse(_store.recents.get(key) ?? '');
          if (value != null) entries.add(MapEntry(key as String, value));
        }
        entries.sort((a, b) => b.value.compareTo(a.value));
        return entries.take(limit).map((e) => e.key).toList();
      }, onError: (e, s) => StorageFailure(
            'Could not read recent projects.',
            cause: e,
            stackTrace: s,
          ));

  @override
  Future<Result<void>> markOpened(String projectId) async => guard(() async {
    await _store.recents.put(
      projectId,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }, onError: (e, s) => StorageFailure(
        'Could not update recent projects.',
        cause: e,
        stackTrace: s,
      ));

  Future<void> dispose() async {
    await _summaries.close();
  }
}
