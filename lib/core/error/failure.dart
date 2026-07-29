/// Typed, user-presentable error taxonomy.
///
/// Nothing in the domain or engine layers throws raw exceptions across a
/// boundary — they return `Result<T>` carrying one of these. The presentation
/// layer maps a [Failure] to a message without needing to know what threw.
library;

import 'package:flutter/foundation.dart';

@immutable
sealed class Failure {
  const Failure(this.message, {this.cause, this.stackTrace});

  /// Human-readable, safe to surface in the UI.
  final String message;

  /// The original error, kept for logging. Never shown to users.
  final Object? cause;
  final StackTrace? stackTrace;

  /// Short stable code used in logs and analytics.
  String get code;

  @override
  String toString() => '$code: $message${cause == null ? '' : ' ($cause)'}';
}

/// Local database read/write problem.
class StorageFailure extends Failure {
  const StorageFailure(super.message, {super.cause, super.stackTrace});
  @override
  String get code => 'storage';
}

/// A project could not be decoded — usually a schema version we cannot read.
class ProjectCorruptFailure extends Failure {
  const ProjectCorruptFailure(
    super.message, {
    this.projectId,
    super.cause,
    super.stackTrace,
  });
  final String? projectId;
  @override
  String get code => 'project_corrupt';
}

/// An FFmpeg/FFprobe invocation returned a non-zero code.
class MediaProcessingFailure extends Failure {
  const MediaProcessingFailure(
    super.message, {
    this.returnCode,
    this.command,
    this.log,
    super.cause,
    super.stackTrace,
  });

  final int? returnCode;
  final String? command;

  /// Tail of the FFmpeg log — the actually useful part for diagnosis.
  final String? log;

  @override
  String get code => 'media_processing';
}

/// The file is missing, unreadable, or not a media container we support.
class UnsupportedMediaFailure extends Failure {
  const UnsupportedMediaFailure(
    super.message, {
    this.path,
    super.cause,
    super.stackTrace,
  });
  final String? path;
  @override
  String get code => 'unsupported_media';
}

/// A runtime permission was denied.
class PermissionFailure extends Failure {
  const PermissionFailure(
    super.message, {
    this.permanentlyDenied = false,
    super.cause,
    super.stackTrace,
  });

  /// True when the user selected "don't ask again" — the UI must deep-link to
  /// app settings instead of re-requesting.
  final bool permanentlyDenied;

  @override
  String get code => 'permission';
}

/// Network/API problem talking to the asset library or a remote AI backend.
class NetworkFailure extends Failure {
  const NetworkFailure(
    super.message, {
    this.statusCode,
    super.cause,
    super.stackTrace,
  });
  final int? statusCode;
  @override
  String get code => 'network';
}

/// The device ran out of storage while writing a render.
class OutOfSpaceFailure extends Failure {
  const OutOfSpaceFailure(
    super.message, {
    this.requiredBytes,
    this.availableBytes,
    super.cause,
    super.stackTrace,
  });
  final int? requiredBytes;
  final int? availableBytes;
  @override
  String get code => 'out_of_space';
}

/// The user cancelled a long-running operation. Not an error — but it travels
/// the same channel, so it is modelled here and filtered out of error UI.
class CancelledFailure extends Failure {
  const CancelledFailure([super.message = 'Operation cancelled']);
  @override
  String get code => 'cancelled';
}

/// An edit was rejected because it would produce an invalid timeline.
class InvalidEditFailure extends Failure {
  const InvalidEditFailure(super.message, {super.cause, super.stackTrace});
  @override
  String get code => 'invalid_edit';
}

/// A feature needs a model/asset that is not installed on this device.
class FeatureUnavailableFailure extends Failure {
  const FeatureUnavailableFailure(
    super.message, {
    this.feature,
    super.cause,
    super.stackTrace,
  });
  final String? feature;
  @override
  String get code => 'feature_unavailable';
}

/// Fallback for genuinely unexpected errors.
class UnknownFailure extends Failure {
  const UnknownFailure(super.message, {super.cause, super.stackTrace});

  const UnknownFailure.generic() : this('Something went wrong');
  @override
  String get code => 'unknown';
}
