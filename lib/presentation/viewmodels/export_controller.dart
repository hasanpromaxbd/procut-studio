/// Export settings and job progress.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/export_job.dart';
import '../../domain/entities/export_preset.dart';
import '../../domain/entities/export_range.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/project.dart';

final exportSettingsProvider =
    NotifierProvider<ExportSettingsController, ExportSettings>(
      ExportSettingsController.new,
    );

class ExportSettingsController extends Notifier<ExportSettings> {
  @override
  ExportSettings build() => const ExportSettings();

  /// Seeds sensible defaults from the project itself: matching the timeline's
  /// frame rate avoids a needless resample, and clamping the resolution avoids
  /// upscaling a 720p edit to 4K, which only wastes bytes.
  void seedFrom(Project project) {
    final height = project.timeline.height;
    final width = project.timeline.width;
    final longEdge = height > width ? height : width;

    final resolution = switch (longEdge) {
      >= 3840 => ExportResolution.k4,
      >= 2560 => ExportResolution.k2,
      >= 1920 => ExportResolution.p1080,
      >= 1280 => ExportResolution.p720,
      _ => ExportResolution.p480,
    };

    state = state.copyWith(
      resolution: resolution,
      fps: project.timeline.fps,
    );
  }

  /// Applies a named target, keeping the user's hardware-encoding choice —
  /// that is a device preference, not a platform requirement.
  void applyPreset(ExportPreset preset) {
    state = preset.settings.copyWith(
      useHardwareEncoder: state.useHardwareEncoder,
      fileNameOverride: state.fileNameOverride,
    );
  }

  void setResolution(ExportResolution value) =>
      state = state.copyWith(resolution: value);
  void setFps(int value) => state = state.copyWith(fps: value);
  void setCodec(VideoCodec value) => state = state.copyWith(videoCodec: value);
  void setContainer(ExportContainer value) =>
      state = state.copyWith(container: value);
  void setQuality(QualityPreset value) => state = state.copyWith(quality: value);
  void setBitrateMode(BitrateMode value) =>
      state = state.copyWith(bitrateMode: value);
  void setCustomBitrate(int kbps) =>
      state = state.copyWith(customVideoBitrateKbps: kbps);
  void setAudioBitrate(int kbps) =>
      state = state.copyWith(audioBitrateKbps: kbps);
  void setHardwareEncoding(bool value) =>
      state = state.copyWith(useHardwareEncoder: value);
  void setNormalizeLoudness(bool value) =>
      state = state.copyWith(normalizeLoudness: value);
  void setFileName(String? name) =>
      state = state.copyWith(fileNameOverride: name);
}

final exportControllerProvider =
    NotifierProvider<ExportController, ExportProgress?>(ExportController.new);

class ExportController extends Notifier<ExportProgress?> {
  static const _log = Log('ExportController');

  StreamSubscription<ExportProgress>? _subscription;
  String? _jobId;

  @override
  ExportProgress? build() {
    ref.onDispose(() => unawaited(_subscription?.cancel()));
    return null;
  }

  bool get isRunning => state != null && !state!.isTerminal;

  Future<void> start(
    Project project,
    ExportSettings settings, {
    ExportRange? range,
  }) async {
    if (isRunning) return;

    final jobId = IdGenerator.exportJob();
    _jobId = jobId;
    _log.i('starting export', fields: {
      'job': jobId,
      'project': project.id,
      if (range != null) 'range': range.toString(),
    });

    await _subscription?.cancel();
    _subscription = ref
        .read(exportRepositoryProvider)
        .export(project, settings, jobId: jobId, range: range)
        .listen(
          (progress) => state = progress,
          onError: (Object error, StackTrace stack) {
            _log.e('export stream failed', error: error, stackTrace: stack);
            state = ExportProgress(
              jobId: jobId,
              stage: ExportStage.failed,
              errorMessage: 'The export failed unexpectedly.',
            );
          },
        );
  }

  Future<void> cancel() async {
    final jobId = _jobId;
    if (jobId == null) return;
    await ref.read(exportRepositoryProvider).cancel(jobId);
  }

  /// Clears a terminal result so the screen returns to its settings form.
  void reset() {
    if (isRunning) return;
    state = null;
    _jobId = null;
  }

  Future<Result<String>> saveToGallery() async {
    final path = state?.outputPath;
    if (path == null) {
      return const Result.err(
        CancelledFailure('There is no finished export to save.'),
      );
    }
    return ref.read(exportRepositoryProvider).publishToGallery(path);
  }

  Future<Result<void>> share() async {
    final path = state?.outputPath;
    if (path == null) {
      return const Result.err(
        CancelledFailure('There is no finished export to share.'),
      );
    }
    return ref
        .read(exportRepositoryProvider)
        .share(path, subject: 'Made with ProCut Studio');
  }
}
