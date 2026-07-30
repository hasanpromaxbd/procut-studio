/// A queue of exports, run strictly one at a time.
///
/// One at a time is a decision, not a limitation: two concurrent FFmpeg
/// encodes on a phone thrash the thermal budget and both finish later than
/// they would in sequence. The queue exists so the user can line up "1080p
/// for YouTube, vertical for Shorts, a 4K master" and walk away.
///
/// Queued jobs snapshot the project at enqueue time. Editing while the queue
/// drains exports what you queued, not what you happen to have on screen when
/// the job's turn comes — the alternative silently exports half-finished
/// edits.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/export_job.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/project.dart';
import 'export_controller.dart';

enum QueuedExportStatus { waiting, running, done, failed, cancelled }

@immutable
class QueuedExport {
  const QueuedExport({
    required this.id,
    required this.project,
    required this.settings,
    required this.label,
    this.status = QueuedExportStatus.waiting,
    this.progress = 0,
    this.outputPath,
    this.errorMessage,
  });

  final String id;

  /// The project as it was when queued — see the library doc.
  final Project project;
  final ExportSettings settings;

  /// What the row shows, e.g. "1080p · H.264 · MP4".
  final String label;

  final QueuedExportStatus status;
  final double progress;
  final String? outputPath;
  final String? errorMessage;

  bool get isFinished =>
      status == QueuedExportStatus.done ||
      status == QueuedExportStatus.failed ||
      status == QueuedExportStatus.cancelled;

  QueuedExport copyWith({
    QueuedExportStatus? status,
    double? progress,
    String? outputPath,
    String? errorMessage,
  }) => QueuedExport(
    id: id,
    project: project,
    settings: settings,
    label: label,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    outputPath: outputPath ?? this.outputPath,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

@immutable
class ExportQueueState {
  const ExportQueueState({this.jobs = const []});

  final List<QueuedExport> jobs;

  bool get isDraining => jobs.any(
    (j) =>
        j.status == QueuedExportStatus.running ||
        j.status == QueuedExportStatus.waiting,
  );
  int get remaining => jobs
      .where(
        (j) =>
            j.status == QueuedExportStatus.waiting ||
            j.status == QueuedExportStatus.running,
      )
      .length;
}

final exportQueueProvider =
    NotifierProvider<ExportQueueController, ExportQueueState>(
      ExportQueueController.new,
    );

class ExportQueueController extends Notifier<ExportQueueState> {
  static const _log = Log('ExportQueue');

  bool _draining = false;

  @override
  ExportQueueState build() => const ExportQueueState();

  /// Adds a job and starts draining if nothing is running.
  void enqueue(Project project, ExportSettings settings) {
    final job = QueuedExport(
      id: IdGenerator.exportJob(),
      project: project,
      settings: settings,
      label:
          '${settings.resolution.label} · '
          '${settings.videoCodec.label} · '
          '${settings.container.label}',
    );
    state = ExportQueueState(jobs: [...state.jobs, job]);
    _log.i('queued', fields: {'job': job.id, 'label': job.label});
    unawaited(_drain());
  }

  /// Removes a waiting job. A running one has to be cancelled, not removed.
  void remove(String jobId) {
    final job = _find(jobId);
    if (job == null || job.status != QueuedExportStatus.waiting) return;
    state = ExportQueueState(
      jobs: state.jobs.where((j) => j.id != jobId).toList(),
    );
  }

  /// Cancels the running job; the queue moves on to the next one.
  Future<void> cancelRunning() =>
      ref.read(exportControllerProvider.notifier).cancel();

  /// Drops finished rows, keeping anything still pending.
  void clearFinished() => state = ExportQueueState(
    jobs: state.jobs.where((j) => !j.isFinished).toList(),
  );

  QueuedExport? _find(String id) =>
      state.jobs.where((j) => j.id == id).firstOrNull;

  void _update(String id, QueuedExport Function(QueuedExport) change) {
    state = ExportQueueState(
      jobs: [
        for (final job in state.jobs)
          if (job.id == id) change(job) else job,
      ],
    );
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final next = state.jobs
            .where((j) => j.status == QueuedExportStatus.waiting)
            .firstOrNull;
        if (next == null) break;

        // The single-export controller stays the one place that talks to the
        // repository, so the notification service and the export screen keep
        // working unchanged whether a job came from the queue or not.
        final exporter = ref.read(exportControllerProvider.notifier);
        if (exporter.isRunning) break; // a direct export owns the encoder

        _update(next.id, (j) => j.copyWith(status: QueuedExportStatus.running));

        await exporter.start(next.project, next.settings);
        final result = await _awaitCompletion();

        _update(next.id, (j) {
          if (result == null) {
            return j.copyWith(
              status: QueuedExportStatus.failed,
              errorMessage: 'The export never reported finishing.',
            );
          }
          return switch (result.stage) {
            ExportStage.completed => j.copyWith(
              status: QueuedExportStatus.done,
              progress: 1,
              outputPath: result.outputPath,
            ),
            ExportStage.cancelled => j.copyWith(
              status: QueuedExportStatus.cancelled,
            ),
            _ => j.copyWith(
              status: QueuedExportStatus.failed,
              errorMessage: result.errorMessage ?? 'Export failed.',
            ),
          };
        });

        exporter.reset();
      }
    } finally {
      _draining = false;
    }
  }

  /// Waits for the current export to reach a terminal stage, mirroring its
  /// progress onto the queue row as it goes.
  Future<ExportProgress?> _awaitCompletion() async {
    final completer = Completer<ExportProgress?>();
    late final ProviderSubscription<ExportProgress?> sub;
    sub = ref.listen(exportControllerProvider, (_, progress) {
      if (progress == null) return;
      final runningId = state.jobs
          .where((j) => j.status == QueuedExportStatus.running)
          .firstOrNull
          ?.id;
      if (runningId != null) {
        _update(runningId, (j) => j.copyWith(progress: progress.progress));
      }
      if (progress.isTerminal && !completer.isCompleted) {
        completer.complete(progress);
      }
    });
    try {
      return await completer.future.timeout(
        const Duration(hours: 2),
        onTimeout: () => null,
      );
    } finally {
      sub.close();
    }
  }
}
