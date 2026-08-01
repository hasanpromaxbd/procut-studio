/// Executes a [RenderPlan] and reports progress.
///
/// Progress is apportioned across three phases so the bar moves at a roughly
/// constant rate rather than sitting at 5% for a minute and then jumping:
///
///   rasterising layers   →  0 … 10%
///   pre-render passes    → 10 … 10% + weighted share
///   main encode          →  … 100%
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/export_service_channel.dart';
import '../../core/services/media_store_channel.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/file_utils.dart';
import '../../domain/entities/export_job.dart';
import '../../domain/entities/export_range.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/project.dart';
import '../../domain/repositories/export_repository.dart';
import '../ffmpeg/ffmpeg_service.dart';
import '../ffmpeg/hardware_encoder.dart';
import '../render/layer_rasteriser.dart';
import 'render_plan.dart';
import 'timeline_compiler.dart';

class ExportEngine implements ExportRepository {
  ExportEngine({
    required FFmpegService ffmpeg,
    required PathService paths,
    required HardwareEncoderProbe encoderProbe,
    required LayerRasteriser rasteriser,
    MediaStorePublisher? publisher,
    ExportServiceChannel? serviceChannel,
    TimelineCompiler compiler = const TimelineCompiler(),
  })  : _ffmpeg = ffmpeg,
        _paths = paths,
        _encoderProbe = encoderProbe,
        _rasteriser = rasteriser,
        _compiler = compiler,
        _publisher = publisher ?? const MediaStorePublisher(),
        _serviceChannel = serviceChannel ?? ExportServiceChannel();

  static const _log = Log('ExportEngine');

  final FFmpegService _ffmpeg;
  final PathService _paths;
  final HardwareEncoderProbe _encoderProbe;
  final LayerRasteriser _rasteriser;
  final MediaStorePublisher _publisher;
  final TimelineCompiler _compiler;
  final ExportServiceChannel _serviceChannel;

  StreamSubscription<void>? _notificationCancelSub;

  final Map<String, ExportJob> _active = {};
  final List<ExportJob> _history = [];
  final Set<String> _cancelled = {};

  static const double _rasterShare = 0.10;

  @override
  Stream<ExportProgress> export(
    Project project,
    ExportSettings settings, {
    required String jobId,
    ExportRange? range,
  }) async* {
    final workspace = _paths.renderWorkspace(jobId);
    var progress = ExportProgress(
      jobId: jobId,
      stage: ExportStage.preparing,
      totalDuration: project.duration,
    );
    yield progress;

    // Validation before any expensive work — failing after four minutes of
    // encoding because the frame rate was 0 is unforgivable.
    final issues = settings.validate();
    if (issues.isNotEmpty) {
      yield progress.copyWith(
        stage: ExportStage.failed,
        errorMessage: issues.first,
      );
      return;
    }
    if (project.duration <= Duration.zero) {
      yield progress.copyWith(
        stage: ExportStage.failed,
        errorMessage: 'There is nothing on the timeline to export.',
      );
      return;
    }

    try {
      await workspace.create(recursive: true);

      // Promote the process before any long work starts. A Cancel tap on the
      // notification unwinds the job exactly like the in-app button does.
      await _serviceChannel.start(
        title: 'Exporting "${project.name}"',
        message: 'Preparing',
      );
      await _notificationCancelSub?.cancel();
      _notificationCancelSub = _serviceChannel.cancelRequests.listen(
        (_) => unawaited(cancel(jobId)),
      );

      final outputFile = await _paths.exportFile(
        settings.fileNameOverride ?? project.name,
        settings.container.extension,
      );

      final (outW, outH) = settings.dimensionsFor(
        project.timeline.width,
        project.timeline.height,
      );

      // Free-space guard. An export that dies at 90% for want of 200 MB is
      // both avoidable and infuriating.
      final estimated = settings.estimatedBytes(
        project.duration,
        project.timeline.width,
        project.timeline.height,
      );
      final free = await _paths.freeSpaceBytes(outputFile.parent);
      if (free != null && free < estimated * 2) {
        yield progress.copyWith(
          stage: ExportStage.failed,
          errorMessage:
              'Not enough free storage. This export needs roughly '
              '${(estimated * 2 / (1024 * 1024)).round()} MB.',
        );
        return;
      }

      var encoder = await _encoderProbe.choose(
        settings,
        width: outW,
        height: outH,
      );
      _log.i('encoder selected', fields: {'encoder': encoder.toString()});

      final job = ExportJob(
        id: jobId,
        projectId: project.id,
        projectName: project.name,
        settings: settings,
        createdAt: DateTime.now(),
      );
      _active[jobId] = job;

      var plan = _compiler.compile(
        project: project,
        settings: settings,
        workspaceDir: workspace.path,
        outputPath: outputFile.path,
        encoder: encoder,
        encoderProbe: _encoderProbe,
        range: range,
      );

      final totalSteps = plan.rasterSteps.length + plan.preRenderSteps.length + 1;
      progress = progress.copyWith(
        totalSteps: totalSteps,
        message: plan.warnings.isEmpty ? null : plan.warnings.first,
      );

      // ── Phase 1: rasterise text / sticker layers ───────────────────
      if (plan.rasterSteps.isNotEmpty) {
        yield progress = progress.copyWith(
          stage: ExportStage.preRendering,
          message: 'Rendering layers',
        );
        var done = 0;
        for (final step in plan.rasterSteps) {
          if (_isCancelled(jobId)) {
            yield progress.copyWith(stage: ExportStage.cancelled);
            return;
          }
          final result = await _rasteriser.rasterise(
            project: project,
            step: step,
            canvasWidth: outW,
            canvasHeight: outH,
            fps: settings.fps,
          );
          if (result.isErr) {
            yield progress.copyWith(
              stage: ExportStage.failed,
              errorMessage: result.failureOrNull!.message,
            );
            return;
          }
          done++;
          yield progress = progress.copyWith(
            progress: _rasterShare * done / plan.rasterSteps.length,
            currentStep: done,
          );
        }
      }

      // ── Phase 2: pre-render passes ─────────────────────────────────
      final preShare = plan.preRenderSteps.isEmpty
          ? 0.0
          : (0.35 * plan.preRenderWeight / (plan.preRenderWeight + 2)).clamp(0.0, 0.35);

      if (plan.preRenderSteps.isNotEmpty) {
        var weightDone = 0.0;
        for (final step in plan.preRenderSteps) {
          if (_isCancelled(jobId)) {
            yield progress.copyWith(stage: ExportStage.cancelled);
            return;
          }
          yield progress = progress.copyWith(
            stage: ExportStage.preRendering,
            message: step.description,
          );

          final stepResult = await _ffmpeg.run(
            step.command,
            jobId: jobId,
            totalDuration: step.estimatedDuration,
          );
          if (stepResult.isErr) {
            final failure = stepResult.failureOrNull!;
            yield progress.copyWith(
              stage: failure is CancelledFailure
                  ? ExportStage.cancelled
                  : ExportStage.failed,
              errorMessage: failure.message,
            );
            return;
          }
          weightDone += step.weight;
          yield progress = progress.copyWith(
            progress: _rasterShare +
                preShare * (weightDone / plan.preRenderWeight),
          );
        }
      }

      // ── Write effect-automation scripts ────────────────────────────
      // Small and fast, so they are not a progress phase of their own. The
      // compiler produced the text; writing is deliberately kept out of it so
      // the compiler stays pure and unit-testable.
      for (final script in plan.commandScripts) {
        await File(script.path).writeAsString(script.contents, flush: true);
      }
      if (plan.commandScripts.isNotEmpty) {
        _log.d(
          'effect automation written',
          fields: {
            'scripts': plan.commandScripts.length,
            'commands': plan.commandScripts.fold<int>(
              0,
              (sum, s) => sum + s.commandCount,
            ),
          },
        );
      }

      // ── Phase 3: main encode ───────────────────────────────────────
      final encodeStart = _rasterShare + preShare;
      yield progress = progress.copyWith(
        stage: ExportStage.encoding,
        progress: encodeStart,
        message: encoder.isHardware
            ? 'Encoding (hardware)'
            : 'Encoding',
      );

      var result = await _runMainPass(
        plan: plan,
        jobId: jobId,
        encodeStart: encodeStart,
        onProgress: (p) {
          progress = progress.copyWith(progress: p);
          _publishProgress(progress);
        },
        onStats: (stats) {
          progress = progress.copyWith(
            processedDuration: stats.processedDuration,
            speed: stats.speed,
            outputBytes: stats.sizeBytes,
          );
        },
      );

      // Hardware encoders fail in device-specific ways. Rather than surfacing
      // a vendor error, retry once in software — the user gets their file.
      if (result.isErr && encoder.isHardware && !_isCancelled(jobId)) {
        final failure = result.failureOrNull;
        if (failure is MediaProcessingFailure) {
          _log.w('hardware encode failed; retrying in software');
          yield progress = progress.copyWith(
            message: 'Hardware encoder failed — retrying in software',
            progress: encodeStart,
          );
          encoder = await _encoderProbe.choose(
            settings,
            width: outW,
            height: outH,
            forceSoftware: true,
          );
          plan = _compiler.compile(
            project: project,
            settings: settings,
            workspaceDir: workspace.path,
            outputPath: outputFile.path,
            encoder: encoder,
            encoderProbe: _encoderProbe,
            // The fallback must render the same window; without this a
            // failed hardware pass would silently retry the whole timeline.
            range: range,
          );
          // Paths are deterministic, so this rewrites the same files.
          for (final script in plan.commandScripts) {
            await File(script.path).writeAsString(script.contents, flush: true);
          }
          result = await _runMainPass(
            plan: plan,
            jobId: jobId,
            encodeStart: encodeStart,
            onProgress: (p) => progress = progress.copyWith(progress: p),
            onStats: (stats) {
              progress = progress.copyWith(
                processedDuration: stats.processedDuration,
                speed: stats.speed,
                outputBytes: stats.sizeBytes,
              );
            },
          );
        }
      }

      if (result.isErr) {
        final failure = result.failureOrNull!;
        await FileUtils.deleteQuietly(outputFile.path);
        yield progress.copyWith(
          stage: failure is CancelledFailure
              ? ExportStage.cancelled
              : ExportStage.failed,
          errorMessage: failure.message,
        );
        return;
      }

      yield progress = progress.copyWith(
        stage: ExportStage.finalising,
        progress: 0.99,
        message: 'Finalising',
      );

      final size = await outputFile.length();
      if (size <= 0) {
        yield progress.copyWith(
          stage: ExportStage.failed,
          errorMessage: 'The render produced an empty file.',
        );
        return;
      }

      final finished = job.copyWith(
        outputPath: outputFile.path,
        completedAt: DateTime.now(),
      );
      _history.insert(0, finished);
      _active.remove(jobId);

      _log.i(
        'export complete',
        fields: {'job': jobId, 'bytes': size, 'path': outputFile.path},
      );

      yield progress.copyWith(
        stage: ExportStage.completed,
        progress: 1,
        outputBytes: size,
        outputPath: outputFile.path,
        message: null,
      );
    } catch (e, s) {
      _log.e('export threw', error: e, stackTrace: s);
      yield progress.copyWith(
        stage: ExportStage.failed,
        errorMessage: 'The export failed unexpectedly.',
      );
    } finally {
      _active.remove(jobId);
      _cancelled.remove(jobId);
      await _notificationCancelSub?.cancel();
      _notificationCancelSub = null;
      // Always stop the service: leaving a foreground notification behind after
      // a finished or failed export is worse than never showing one.
      await _serviceChannel.stop();
      await FileUtils.deleteDirQuietly(workspace);
    }
  }

  Future<Result<FfmpegRunOutput>> _runMainPass({
    required RenderPlan plan,
    required String jobId,
    required double encodeStart,
    required void Function(double progress) onProgress,
    required void Function(FfmpegStats stats) onStats,
  }) {
    final span = 0.99 - encodeStart;
    return _ffmpeg.run(
      plan.buildCommand(),
      jobId: jobId,
      totalDuration: plan.duration,
      onStats: onStats,
      onProgress: (p) => onProgress(encodeStart + span * p),
    );
  }

  int _lastPublishedPercent = -1;

  /// Mirrors progress into the notification.
  ///
  /// Throttled to whole percentage points: FFmpeg reports statistics several
  /// times a second, and re-posting a notification that often is a measurable
  /// battery cost for no visible benefit.
  void _publishProgress(ExportProgress progress) {
    final percent = progress.percent;
    if (percent == _lastPublishedPercent) return;
    _lastPublishedPercent = percent;

    unawaited(
      _serviceChannel.update(
        message: progress.message ?? progress.stage.label,
        progress: percent,
        indeterminate: progress.progress <= 0,
      ),
    );
  }

  bool _isCancelled(String jobId) => _cancelled.contains(jobId);

  @override
  Future<Result<void>> cancel(String jobId) async {
    _cancelled.add(jobId);
    await _ffmpeg.cancel(jobId);
    _active.remove(jobId);
    return const Result.ok(null);
  }

  @override
  Future<Result<List<ExportJob>>> activeJobs() async =>
      Result.ok(_active.values.toList());

  @override
  Future<Result<List<ExportJob>>> history({int limit = 20}) async =>
      Result.ok(_history.take(limit).toList());

  @override
  Future<Result<String>> publishToGallery(String filePath) =>
      _publisher.publish(filePath);

  @override
  Future<Result<void>> share(String filePath, {String? subject}) =>
      _publisher.share(filePath, subject: subject);
}

/// Bridges to the Android MediaStore so a finished render shows up in the
/// gallery, and to the system share sheet.
///
/// Scoped storage means an app cannot simply write into `DCIM/`; the file has
/// to be inserted through MediaStore. That work happens in
/// `MainActivity.kt`, which this calls over a method channel.
class MediaStorePublisher {
  const MediaStorePublisher();

  static const _log = Log('MediaStore');

  Future<Result<String>> publish(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return Result.err(
        UnsupportedMediaFailure('That file no longer exists.', path: filePath),
      );
    }
    try {
      final uri = await AndroidMediaStoreChannel.insertVideo(
        filePath: filePath,
        displayName: p.basename(filePath),
      );
      if (uri == null) {
        return const Result.err(
          StorageFailure('Could not add the video to your gallery.'),
        );
      }
      _log.i('published to gallery', fields: {'uri': uri});
      return Result.ok(uri);
    } catch (e, s) {
      _log.e('publish failed', error: e, stackTrace: s);
      return Result.err(
        StorageFailure(
          'Could not add the video to your gallery.',
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  Future<Result<void>> share(String filePath, {String? subject}) async =>
      SharePublisher.share(filePath, subject: subject);
}
