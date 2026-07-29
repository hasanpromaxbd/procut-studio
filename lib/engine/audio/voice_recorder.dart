/// Voice-over capture.
///
/// Wraps the platform recorder with the two things the UI actually needs and
/// the plugin does not give directly: a bounded amplitude history for drawing a
/// live meter, and a recording that lands somewhere the project can keep.
///
/// Recordings are written to the app's documents directory, not the cache —
/// a voice-over the user just performed is not regenerable, and Android will
/// reclaim cache space without warning.
library;

import 'dart:async';

import 'package:record/record.dart';

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/file_utils.dart';
import '../../core/utils/id_generator.dart';

/// A snapshot of the live meter.
class RecordingLevel {
  const RecordingLevel({required this.current, required this.peak});

  /// Current amplitude in dBFS (negative; 0 is full scale).
  final double current;
  final double peak;

  /// 0..1 for a meter widget, mapping a useful −45 dB … 0 dB window.
  double get normalised {
    const floor = -45.0;
    if (current <= floor) return 0;
    if (current >= 0) return 1;
    return (current - floor) / -floor;
  }

  /// True when the signal is close enough to full scale to clip. Worth showing:
  /// a clipped voice-over cannot be fixed afterwards.
  bool get isClipping => current > -1.0;
}

class VoiceRecorder {
  VoiceRecorder({required PathService paths, AudioRecorder? recorder})
    : _paths = paths,
      _recorder = recorder ?? AudioRecorder();

  static const _log = Log('VoiceRecorder');

  final PathService _paths;
  final AudioRecorder _recorder;

  String? _currentPath;
  DateTime? _startedAt;
  Duration _pausedTotal = Duration.zero;
  DateTime? _pausedAt;

  StreamSubscription<Amplitude>? _amplitudeSub;
  final StreamController<RecordingLevel> _levels =
      StreamController<RecordingLevel>.broadcast();

  /// Live meter, sampled while recording.
  Stream<RecordingLevel> get levels => _levels.stream;

  bool get isActive => _currentPath != null;

  /// Elapsed recording time, excluding any paused stretches.
  Duration get elapsed {
    final started = _startedAt;
    if (started == null) return Duration.zero;
    final until = _pausedAt ?? DateTime.now();
    return until.difference(started) - _pausedTotal;
  }

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<Result<void>> start() async {
    if (isActive) {
      return const Result.err(
        InvalidEditFailure('A recording is already in progress.'),
      );
    }

    if (!await _recorder.hasPermission()) {
      return const Result.err(
        PermissionFailure('Microphone access is needed to record a voice-over.'),
      );
    }

    try {
      final file = _paths.recordingFile(IdGenerator.sortable('rec'));
      await file.parent.create(recursive: true);

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          // 48 kHz matches the export sample rate, so the mix never resamples
          // the voice-over — resampling is the one avoidable quality loss here.
          sampleRate: 48000,
          numChannels: 1,
          bitRate: 128000,
        ),
        path: file.path,
      );

      _currentPath = file.path;
      _startedAt = DateTime.now();
      _pausedTotal = Duration.zero;
      _pausedAt = null;

      var peak = -160.0;
      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) {
            if (amplitude.current > peak) peak = amplitude.current;
            if (!_levels.isClosed) {
              _levels.add(
                RecordingLevel(current: amplitude.current, peak: peak),
              );
            }
          });

      _log.i('recording started', fields: {'path': file.path});
      return const Result.ok(null);
    } catch (e, s) {
      _log.e('start failed', error: e, stackTrace: s);
      await _cleanUp();
      return Result.err(
        UnknownFailure(
          'Could not start recording.',
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  Future<void> pause() async {
    if (!isActive || _pausedAt != null) return;
    await _recorder.pause();
    _pausedAt = DateTime.now();
  }

  Future<void> resume() async {
    final pausedAt = _pausedAt;
    if (!isActive || pausedAt == null) return;
    _pausedTotal += DateTime.now().difference(pausedAt);
    _pausedAt = null;
    await _recorder.resume();
  }

  /// Stops and returns the finished file path.
  Future<Result<String>> stop() async {
    if (!isActive) {
      return const Result.err(
        InvalidEditFailure('Nothing is being recorded.'),
      );
    }

    try {
      final path = await _recorder.stop() ?? _currentPath;
      await _cleanUp();

      if (path == null) {
        return const Result.err(
          UnknownFailure('The recording produced no file.'),
        );
      }
      _log.i('recording stopped', fields: {'path': path});
      return Result.ok(path);
    } catch (e, s) {
      _log.e('stop failed', error: e, stackTrace: s);
      await _cleanUp();
      return Result.err(
        UnknownFailure('Could not finish the recording.', cause: e, stackTrace: s),
      );
    }
  }

  /// Aborts and deletes the partial file.
  Future<void> cancel() async {
    if (!isActive) return;
    final path = _currentPath;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped or never started cleanly; the delete below is what
      // actually matters.
    }
    await _cleanUp();
    await FileUtils.deleteQuietly(path);
  }

  Future<void> _cleanUp() async {
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _currentPath = null;
    _startedAt = null;
    _pausedAt = null;
    _pausedTotal = Duration.zero;
  }

  Future<void> dispose() async {
    await cancel();
    await _levels.close();
    await _recorder.dispose();
  }
}
