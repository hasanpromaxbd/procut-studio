/// Thin, cancellable wrapper over FFmpegKit.
///
/// Everything that shells out to FFmpeg goes through here so we have one place
/// that: tracks running sessions (for cancel), keeps a bounded tail of the log
/// (for error reporting — the last 40 lines are where the actual cause is), and
/// converts return codes into typed failures.
library;

import 'dart:async';
import 'dart:collection';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';

/// Live numbers from a running encode.
class FfmpegStats {
  const FfmpegStats({
    required this.processedDuration,
    required this.speed,
    required this.bitrate,
    required this.sizeBytes,
    required this.frameNumber,
    required this.fps,
  });

  /// Output timestamp reached so far.
  final Duration processedDuration;

  /// Multiple of realtime, e.g. 2.4 means 2.4× faster than playback.
  final double speed;

  final double bitrate;
  final int sizeBytes;
  final int frameNumber;
  final double fps;

  /// Progress against a known output length.
  double progressAgainst(Duration total) {
    if (total <= Duration.zero) return 0;
    return (processedDuration.inMicroseconds / total.inMicroseconds)
        .clamp(0.0, 1.0);
  }
}

class FfmpegRunOutput {
  const FfmpegRunOutput({
    required this.sessionId,
    required this.durationMs,
    required this.logTail,
  });

  final int sessionId;
  final int durationMs;
  final String logTail;
}

class FFmpegService {
  FFmpegService();

  static const _log = Log('FFmpegService');

  /// jobId → session, so a UI cancel can reach the right process.
  final Map<String, FFmpegSession> _sessions = {};

  /// Serialises heavy invocations. Android devices have one hardware encoder;
  /// running two encodes at once makes both slower and can hard-fail on
  /// MediaCodec. Light calls (thumbnails) pass `queued: false`.
  final Queue<Completer<void>> _queue = Queue();
  bool _busy = false;

  bool get isBusy => _busy;
  int get runningCount => _sessions.length;

  /// Reduces FFmpegKit's own log volume. Call once at startup.
  Future<void> configure({bool verbose = false}) async {
    await FFmpegKitConfig.setLogLevel(verbose ? 32 /* info */ : 16 /* error */);
  }

  /// Runs [command] to completion.
  ///
  /// [totalDuration] lets progress be reported as a fraction; without it
  /// [onStats] still fires but callers can only show a spinner.
  Future<Result<FfmpegRunOutput>> run(
    String command, {
    String? jobId,
    Duration? totalDuration,
    void Function(FfmpegStats stats)? onStats,
    void Function(double progress)? onProgress,
    bool queued = true,
  }) async {
    if (queued) await _acquire();
    final logTail = _LogTail();
    final completer = Completer<Result<FfmpegRunOutput>>();

    try {
      _log.d('exec', fields: {'job': jobId, 'cmd': _elide(command)});

      final session = await FFmpegKit.executeAsync(
        command,
        (session) async {
          final returnCode = await session.getReturnCode();
          final durationMs = await session.getDuration();
          final sessionId = session.getSessionId();

          if (jobId != null) _sessions.remove(jobId);

          if (ReturnCode.isSuccess(returnCode)) {
            _log.d('done', fields: {'job': jobId, 'ms': durationMs});
            completer.complete(
              Result.ok(
                FfmpegRunOutput(
                  sessionId: sessionId ?? -1,
                  durationMs: durationMs,
                  logTail: logTail.text,
                ),
              ),
            );
          } else if (ReturnCode.isCancel(returnCode)) {
            _log.i('cancelled', fields: {'job': jobId});
            completer.complete(const Result.err(CancelledFailure()));
          } else {
            final tail = logTail.text;
            _log.e(
              'failed',
              fields: {
                'job': jobId,
                'rc': returnCode?.getValue(),
                'tail': _elide(tail, 400),
              },
            );
            completer.complete(
              Result.err(
                MediaProcessingFailure(
                  _humanise(tail),
                  returnCode: returnCode?.getValue(),
                  command: command,
                  log: tail,
                ),
              ),
            );
          }
        },
        (log) => logTail.add(log.getMessage()),
        (Statistics statistics) {
          final stats = FfmpegStats(
            processedDuration: Duration(milliseconds: statistics.getTime()),
            speed: statistics.getSpeed(),
            bitrate: statistics.getBitrate(),
            sizeBytes: statistics.getSize(),
            frameNumber: statistics.getVideoFrameNumber(),
            fps: statistics.getVideoFps(),
          );
          onStats?.call(stats);
          if (onProgress != null && totalDuration != null) {
            onProgress(stats.progressAgainst(totalDuration));
          }
        },
      );

      if (jobId != null) _sessions[jobId] = session;
      return await completer.future;
    } catch (e, s) {
      if (jobId != null) _sessions.remove(jobId);
      _log.e('threw', error: e, stackTrace: s);
      return Result.err(
        MediaProcessingFailure(
          'Could not start the media engine.',
          command: command,
          cause: e,
          stackTrace: s,
        ),
      );
    } finally {
      if (queued) _release();
    }
  }

  /// Runs several commands in order, reporting overall progress across them.
  /// Stops at the first failure and returns it.
  Future<Result<void>> runSequence(
    List<String> commands, {
    String? jobId,
    List<Duration>? durations,
    void Function(int index, double stepProgress, double overall)? onProgress,
  }) async {
    for (var i = 0; i < commands.length; i++) {
      final result = await run(
        commands[i],
        jobId: jobId,
        totalDuration: durations != null && i < durations.length
            ? durations[i]
            : null,
        onProgress: (p) => onProgress?.call(i, p, (i + p) / commands.length),
      );
      if (result.isErr) return Result.err(result.failureOrNull!);
    }
    return const Result.ok(null);
  }

  Future<void> cancel(String jobId) async {
    final session = _sessions.remove(jobId);
    if (session == null) return;
    _log.i('cancel requested', fields: {'job': jobId});
    await session.cancel();
  }

  Future<void> cancelAll() async {
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await cancel(id);
    }
    await FFmpegKit.cancel();
  }

  Future<void> _acquire() async {
    if (!_busy) {
      _busy = true;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _busy = false;
    }
  }

  /// Turns an FFmpeg log tail into something worth showing a user.
  ///
  /// FFmpeg's diagnostics are precise but unreadable; these are the failures
  /// that actually happen in the field on Android.
  static String _humanise(String logTail) {
    final lower = logTail.toLowerCase();
    if (lower.contains('no space left')) {
      return 'The device ran out of storage during the render.';
    }
    if (lower.contains('permission denied')) {
      return 'ProCut could not read one of the media files. '
          'Re-import it and try again.';
    }
    if (lower.contains('no such file or directory')) {
      return 'A media file used by this project is missing. '
          'Relink it and try again.';
    }
    if (lower.contains('invalid data found') ||
        lower.contains('moov atom not found')) {
      return 'One of the media files is damaged or incomplete.';
    }
    if (lower.contains('height not divisible by 2') ||
        lower.contains('width not divisible by 2')) {
      return 'The export size is invalid. Pick a standard resolution.';
    }
    if (lower.contains('mediacodec') || lower.contains('cannot open encoder')) {
      return 'The hardware encoder refused this format. '
          'Turn off hardware encoding in export settings and retry.';
    }
    if (lower.contains('conversion failed')) {
      return 'The render failed while encoding.';
    }
    return 'The render failed. See diagnostics for details.';
  }

  static String _elide(String value, [int max = 220]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}

/// Bounded log buffer — FFmpeg can emit tens of thousands of lines and we only
/// ever need the tail, so this never grows.
class _LogTail {
  _LogTail();

  static const int maxLines = 40;
  final Queue<String> _lines = Queue<String>();

  void add(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _lines.addLast(trimmed);
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  String get text => _lines.join('\n');
}
