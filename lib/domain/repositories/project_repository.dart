/// Contract for project persistence. The domain never learns that Hive exists.
library;

import '../../core/error/result.dart';
import '../entities/project.dart';

abstract interface class ProjectRepository {
  /// Lightweight rows for the home grid, newest first.
  Future<Result<List<ProjectSummary>>> listSummaries();

  /// Emits whenever any project is created, saved or deleted.
  Stream<List<ProjectSummary>> watchSummaries();

  Future<Result<Project>> load(String projectId);

  /// Persists the project and rotates a backup copy.
  Future<Result<void>> save(Project project);

  Future<Result<void>> delete(String projectId);

  /// Deep-copies a project under a new id and name.
  Future<Result<Project>> duplicate(String projectId, {String? newName});

  Future<Result<void>> rename(String projectId, String name);

  /// Writes a portable `.pcstudio` bundle (project JSON + referenced media).
  /// Returns the bundle path.
  Future<Result<String>> exportBundle(String projectId, {String? destination});

  /// Reads a `.pcstudio` bundle, re-homing media into app storage.
  Future<Result<Project>> importBundle(String bundlePath);

  /// Rolling backups, newest first.
  Future<Result<List<DateTime>>> listBackups(String projectId);

  Future<Result<Project>> restoreBackup(String projectId, int backupIndex);

  /// Most recently opened project ids, newest first.
  Future<Result<List<String>>> recentProjectIds({int limit = 10});

  Future<Result<void>> markOpened(String projectId);
}
