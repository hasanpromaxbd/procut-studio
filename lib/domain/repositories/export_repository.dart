/// Contract for rendering a project to a file.
library;

import '../../core/error/result.dart';
import '../entities/export_job.dart';
import '../entities/export_range.dart';
import '../entities/export_settings.dart';
import '../entities/project.dart';

abstract interface class ExportRepository {
  /// Starts a render. The returned stream emits until a terminal stage and
  /// then closes. Cancelling the subscription does **not** cancel the job —
  /// call [cancel] for that, so navigating away does not bin a 20-minute
  /// export.
  /// [range] renders only a window of the timeline. The edit is unchanged —
  /// the compiler trims the tail of the same graph — so what comes out is a
  /// true sample of the full render, which is the point of a test render.
  Stream<ExportProgress> export(
    Project project,
    ExportSettings settings, {
    required String jobId,
    ExportRange? range,
  });

  Future<Result<void>> cancel(String jobId);

  /// Jobs still running, e.g. after returning to the app.
  Future<Result<List<ExportJob>>> activeJobs();

  Future<Result<List<ExportJob>>> history({int limit = 20});

  /// Makes the finished file visible to the gallery via MediaStore.
  Future<Result<String>> publishToGallery(String filePath);

  Future<Result<void>> share(String filePath, {String? subject});
}
