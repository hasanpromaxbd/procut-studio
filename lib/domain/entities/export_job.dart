/// A render in flight.
library;

import 'package:flutter/foundation.dart';

import 'export_settings.dart';

enum ExportStage {
  queued('Queued'),
  preparing('Preparing'),

  /// Pre-rendering pieces FFmpeg cannot do in one graph (reversed clips,
  /// rasterised text/stickers).
  preRendering('Rendering layers'),

  /// The main filter-graph pass.
  encoding('Encoding'),

  /// Remux/faststart so the file streams without a full download.
  finalising('Finalising'),

  completed('Completed'),
  failed('Failed'),
  cancelled('Cancelled');

  const ExportStage(this.label);
  final String label;

  bool get isTerminal =>
      this == ExportStage.completed ||
      this == ExportStage.failed ||
      this == ExportStage.cancelled;

  bool get isRunning => !isTerminal && this != ExportStage.queued;
}

@immutable
class ExportProgress {
  const ExportProgress({
    required this.jobId,
    required this.stage,
    this.progress = 0,
    this.processedDuration = Duration.zero,
    this.totalDuration = Duration.zero,
    this.speed = 0,
    this.outputBytes = 0,
    this.currentStep = 0,
    this.totalSteps = 1,
    this.message,
    this.outputPath,
    this.errorMessage,
  });

  final String jobId;
  final ExportStage stage;

  /// Overall 0..1 across every stage, not just the current one.
  final double progress;

  final Duration processedDuration;
  final Duration totalDuration;

  /// Encode rate relative to realtime, straight from FFmpeg statistics.
  final double speed;

  final int outputBytes;
  final int currentStep;
  final int totalSteps;
  final String? message;
  final String? outputPath;
  final String? errorMessage;

  bool get isTerminal => stage.isTerminal;
  bool get isSuccess => stage == ExportStage.completed;

  /// Time remaining, estimated from FFmpeg's reported speed. Null until the
  /// encoder has produced a usable rate — showing "calculating…" beats showing
  /// a wildly wrong number for the first few seconds.
  Duration? get estimatedTimeRemaining {
    if (speed <= 0.01 || totalDuration == Duration.zero) return null;
    final remaining = totalDuration - processedDuration;
    if (remaining <= Duration.zero) return Duration.zero;
    return Duration(
      microseconds: (remaining.inMicroseconds / speed).round(),
    );
  }

  int get percent => (progress.clamp(0.0, 1.0) * 100).round();

  ExportProgress copyWith({
    ExportStage? stage,
    double? progress,
    Duration? processedDuration,
    Duration? totalDuration,
    double? speed,
    int? outputBytes,
    int? currentStep,
    int? totalSteps,
    String? message,
    String? outputPath,
    String? errorMessage,
  }) => ExportProgress(
    jobId: jobId,
    stage: stage ?? this.stage,
    progress: progress ?? this.progress,
    processedDuration: processedDuration ?? this.processedDuration,
    totalDuration: totalDuration ?? this.totalDuration,
    speed: speed ?? this.speed,
    outputBytes: outputBytes ?? this.outputBytes,
    currentStep: currentStep ?? this.currentStep,
    totalSteps: totalSteps ?? this.totalSteps,
    message: message ?? this.message,
    outputPath: outputPath ?? this.outputPath,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  @override
  String toString() =>
      'ExportProgress($jobId, ${stage.label}, $percent%)';
}

@immutable
class ExportJob {
  const ExportJob({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.settings,
    required this.createdAt,
    this.outputPath,
    this.completedAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final ExportSettings settings;
  final DateTime createdAt;
  final String? outputPath;
  final DateTime? completedAt;

  ExportJob copyWith({String? outputPath, DateTime? completedAt}) => ExportJob(
    id: id,
    projectId: projectId,
    projectName: projectName,
    settings: settings,
    createdAt: createdAt,
    outputPath: outputPath ?? this.outputPath,
    completedAt: completedAt ?? this.completedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'projectName': projectName,
    'settings': settings.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (outputPath != null) 'output': outputPath,
    if (completedAt != null) 'completedAt': completedAt!.millisecondsSinceEpoch,
  };

  factory ExportJob.fromJson(Map<String, dynamic> json) => ExportJob(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    projectName: json['projectName'] as String? ?? '',
    settings: ExportSettings.fromJson(
      (json['settings'] as Map?)?.cast<String, dynamic>(),
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num?)?.toInt() ?? 0,
    ),
    outputPath: json['output'] as String?,
    completedAt: json['completedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['completedAt'] as num).toInt(),
          ),
  );
}
