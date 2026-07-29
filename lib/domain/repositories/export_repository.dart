/// Contract for rendering a project to a file.
library;

import '../../core/error/result.dart';
import '../entities/export_job.dart';
import '../entities/export_settings.dart';
import '../entities/project.dart';

abstract interface class ExportRepository {
  /// Starts a render. The returned stream emits until a terminal stage and
  /// then closes. Cancelling the subscription does **not** cancel the job —
  /// call [cancel] for that, so navigating away does not bin a 20-minute
  /// export.
  Stream<ExportProgress> export(
    Project project,
    ExportSettings settings, {
    required String jobId,
  });

  Future<Result<void>> cancel(String jobId);

  /// Jobs still running, e.g. after returning to the app.
  Future<Result<List<ExportJob>>> activeJobs();

  Future<Result<List<ExportJob>>> history({int limit = 20});

  /// Makes the finished file visible to the gallery via MediaStore.
  Future<Result<String>> publishToGallery(String filePath);

  Future<Result<void>> share(String filePath, {String? subject});
}
