/// [AiRepository] implementation.
///
/// Split cleanly in two, because the two halves have completely different
/// reliability characteristics and the UI needs to know which is which:
///
///  * **Local** — scene detection, colour enhancement, upscaling and voice
///    isolation are FFmpeg filter chains. They ship in the app, work offline,
///    and are deterministic. They are "AI" in the marketing sense only, and
///    the code says so rather than implying a model is involved.
///  * **Remote** — captions, background removal and tracking need real models.
///    They are delegated to an [AiBackend]. The app bundles no weights, so with
///    nothing configured these fail fast with `FeatureUnavailableFailure` and
///    the UI offers a settings link instead of hanging.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/services/path_service.dart';
import '../../core/utils/file_utils.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/subtitle.dart';
import '../../domain/repositories/ai_repository.dart';
import '../ffmpeg/ffmpeg_service.dart';

class AiService implements AiRepository {
  AiService({
    required FFmpegService ffmpeg,
    required PathService paths,
    AiBackend? backend,
  }) : _ffmpeg = ffmpeg,
       _paths = paths,
       _backend = backend;

  static const _log = Log('AiService');

  final FFmpegService _ffmpeg;
  final PathService _paths;
  AiBackend? _backend;

  set backend(AiBackend? value) => _backend = value;

  @override
  Future<bool> hasBackend() async => await _backend?.isReachable() ?? false;

  @override
  Future<Set<AiCapability>> availableCapabilities() async {
    final local = AiCapability.values.where((c) => !c.requiresModel).toSet();
    if (!await hasBackend()) return local;
    final remote = await _backend!.capabilities();
    return {...local, ...remote};
  }

  Failure get _noBackend => const FeatureUnavailableFailure(
    'This needs an AI backend. Add one in Settings → AI to enable it.',
    feature: 'ai_backend',
  );

  // ───────────────────────────────────────────────────────────────────
  // Model-backed
  // ───────────────────────────────────────────────────────────────────

  @override
  Future<Result<SubtitleTrack>> autoCaption(
    MediaAsset asset, {
    String? languageHint,
    void Function(double progress)? onProgress,
  }) async {
    final backend = _backend;
    if (backend == null || !await backend.isReachable()) {
      return Result.err(_noBackend);
    }

    // Send compressed mono audio, not the video: a 200 MB clip becomes a 2 MB
    // upload, which matters on a phone connection.
    onProgress?.call(0.05);
    final audioResult = await _extractSpeechAudio(asset);
    if (audioResult.isErr) return Result.err(audioResult.failureOrNull!);
    final audio = audioResult.valueOrNull!;

    try {
      onProgress?.call(0.15);
      final result = await backend.transcribe(
        audioFile: audio,
        languageHint: languageHint,
        onProgress: (p) => onProgress?.call(0.15 + p * 0.85),
      );
      return result.map((track) => track.wrapped());
    } finally {
      await FileUtils.deleteQuietly(audio.path);
    }
  }

  @override
  Future<Result<String>> removeBackground(
    MediaAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    final backend = _backend;
    if (backend == null || !await backend.isReachable()) {
      return Result.err(_noBackend);
    }
    return backend.matte(
      videoPath: asset.path,
      outputPath: p.join(_paths.tempDir.path, 'matte_${asset.id}.mp4'),
      onProgress: onProgress,
    );
  }

  @override
  Future<Result<TrackingResult>> trackObject(
    MediaAsset asset, {
    required double x,
    required double y,
    required double width,
    required double height,
    required Duration from,
    Duration? to,
    void Function(double progress)? onProgress,
  }) async {
    final backend = _backend;
    if (backend == null || !await backend.isReachable()) {
      return Result.err(_noBackend);
    }
    return backend.track(
      videoPath: asset.path,
      x: x,
      y: y,
      width: width,
      height: height,
      from: from,
      to: to ?? asset.duration,
      onProgress: onProgress,
    );
  }

  @override
  Future<Result<List<TrackingResult>>> trackFaces(
    MediaAsset asset, {
    Duration? from,
    Duration? to,
    void Function(double progress)? onProgress,
  }) async {
    final backend = _backend;
    if (backend == null || !await backend.isReachable()) {
      return Result.err(_noBackend);
    }
    return backend.trackFaces(
      videoPath: asset.path,
      from: from ?? Duration.zero,
      to: to ?? asset.duration,
      onProgress: onProgress,
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Local signal processing
  // ───────────────────────────────────────────────────────────────────

  @override
  @override
  Future<Result<String>> synthesizeSpeech(
    String text, {
    String voice = 'alloy',
    void Function(double progress)? onProgress,
  }) async {
    final backend = _backend;
    if (backend == null) {
      return const Result.err(
        FeatureUnavailableFailure(
          'Voiceover needs an AI server — set one up in Settings.',
        ),
      );
    }
    if (text.trim().isEmpty) {
      return const Result.err(CancelledFailure('Nothing to say.'));
    }
    final out = p.join(
      _paths.recordingsDir.path,
      'tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _paths.recordingsDir.create(recursive: true);
    return backend.speech(
      text: text,
      voice: voice,
      outputPath: out,
      onProgress: onProgress,
    );
  }

  @override
  Future<Result<List<SceneCut>>> detectScenes(
    MediaAsset asset, {
    double threshold = 0.35,
    void Function(double progress)? onProgress,
  }) async {
    // FFmpeg's `scdet` filter reports a per-frame scene score in the log. We
    // parse it out rather than writing frames anywhere — `-f null -` means the
    // decode happens but nothing is encoded, so this is fast.
    final command = [
      '-hide_banner',
      '-i', _quote(asset.previewPath),
      '-vf', 'scdet=threshold=${(threshold * 100).toStringAsFixed(1)}',
      '-an',
      '-f', 'null', '-',
    ].join(' ');

    final cuts = <SceneCut>[];
    // Lines look like:
    //   [scdet @ 0x...] lavfi.scd.score: 12.345, lavfi.scd.time: 4.5
    final pattern = RegExp(
      r'score:\s*([\d.]+).*?time:\s*([\d.]+)',
      caseSensitive: false,
    );

    final result = await _ffmpeg.run(
      command,
      totalDuration: asset.duration,
      onProgress: onProgress,
      onStats: (_) {},
    );

    return result.fold(
      (output) {
        for (final match in pattern.allMatches(output.logTail)) {
          final score = double.tryParse(match.group(1) ?? '') ?? 0;
          final seconds = double.tryParse(match.group(2) ?? '') ?? 0;
          cuts.add(
            SceneCut(
              time: Duration(microseconds: (seconds * 1e6).round()),
              score: (score / 100).clamp(0.0, 1.0),
            ),
          );
        }
        _log.i('scene cuts found', fields: {'count': cuts.length});
        return Result.ok(cuts);
      },
      Result.err,
    );
  }

  @override
  Future<Result<Map<String, double>>> frameStatistics(
    MediaAsset asset, {
    Duration? sampleAt,
  }) async {
    final at =
        sampleAt ?? Duration(microseconds: asset.duration.inMicroseconds ~/ 3);
    final command = [
      '-hide_banner',
      '-ss', (at.inMicroseconds / 1e6).toStringAsFixed(3),
      '-i', _quote(asset.previewPath),
      '-frames:v', '1',
      '-vf', 'signalstats,metadata=print',
      '-an',
      '-f', 'null', '-',
    ].join(' ');

    final result = await _ffmpeg.run(command, queued: false);
    return result.fold(
      (output) {
        final stats = _parseSignalStats(output.logTail);
        if (stats.isEmpty) {
          return const Result.err(
            MediaProcessingFailure('Could not read a frame to measure.'),
          );
        }
        return Result.ok(stats);
      },
      Result.err,
    );
  }

  @override
  Future<Result<Map<String, double>>> suggestColorEnhancement(
    MediaAsset asset, {
    Duration? sampleAt,
  }) async {
    // Measure the frame with `signalstats`, then derive corrections from the
    // luma statistics. This is an auto-levels pass, honestly named.
    final at = sampleAt ?? Duration(microseconds: asset.duration.inMicroseconds ~/ 3);
    final command = [
      '-hide_banner',
      '-ss', (at.inMicroseconds / 1e6).toStringAsFixed(3),
      '-i', _quote(asset.previewPath),
      '-frames:v', '1',
      '-vf', 'signalstats,metadata=print',
      '-an',
      '-f', 'null', '-',
    ].join(' ');

    final result = await _ffmpeg.run(command, queued: false);
    return result.fold(
      (output) {
        final stats = _parseSignalStats(output.logTail);
        final yAvg = stats['YAVG'] ?? 128;
        final yLow = stats['YLOW'] ?? 16;
        final yHigh = stats['YHIGH'] ?? 235;
        final sat = stats['SATAVG'] ?? 60;

        // Pull the average toward mid-grey, expand a compressed range, and
        // lift saturation only when the frame is genuinely flat.
        final brightness = ((128 - yAvg) / 255 * 0.6).clamp(-0.3, 0.3);
        final range = (yHigh - yLow).clamp(1, 255);
        final contrast = (219 / range).clamp(0.9, 1.6);
        final saturation = sat < 40
            ? (1 + (40 - sat) / 60).clamp(1.0, 1.4)
            : 1.0;

        _log.i(
          'colour suggestion',
          fields: {
            'brightness': brightness.toStringAsFixed(3),
            'contrast': contrast.toStringAsFixed(3),
            'saturation': saturation.toStringAsFixed(3),
          },
        );
        return Result.ok({
          'brightness': brightness.toDouble(),
          'contrast': contrast.toDouble(),
          'saturation': saturation.toDouble(),
          'gamma': 1.0,
        });
      },
      Result.err,
    );
  }

  @override
  Future<Result<String>> upscale(
    MediaAsset asset, {
    required int targetHeight,
    void Function(double progress)? onProgress,
  }) async {
    final output = p.join(
      _paths.tempDir.path,
      'upscaled_${asset.id}_${targetHeight}p.mp4',
    );

    // Lanczos plus a restrained unsharp is the best classical upscale there
    // is. It does not invent detail — nothing local can — but it avoids the
    // soft, plasticky look of a plain bilinear stretch.
    final command = [
      '-y', '-hide_banner',
      '-i', _quote(asset.path),
      '-vf',
      'scale=-2:$targetHeight:flags=lanczos,unsharp=5:5:0.6:5:5:0.0',
      '-c:v', 'libx264', '-preset', 'medium', '-crf', '18',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'copy',
      _quote(output),
    ].join(' ');

    final result = await _ffmpeg.run(
      command,
      totalDuration: asset.duration,
      onProgress: onProgress,
    );
    return result.map((_) => output);
  }

  @override
  Future<Result<String>> isolateVoice(
    MediaAsset asset, {
    double strength = 0.7,
    void Function(double progress)? onProgress,
  }) async {
    final output = p.join(_paths.tempDir.path, 'voice_${asset.id}.m4a');
    final clamped = strength.clamp(0.0, 1.0);

    // A speech-band chain, not source separation: high-pass out rumble,
    // low-pass out hiss, spectral-gate the noise floor, then level the result.
    // It cleans a voice note substantially; it will not lift a vocal out of a
    // music mix, and the UI copy says as much.
    final filters = [
      'highpass=f=${(80 + clamped * 40).round()}',
      'lowpass=f=${(9000 - clamped * 2000).round()}',
      'afftdn=nr=${(12 + clamped * 21).round()}:nf=-25:tn=1',
      'compand=attacks=0:points=-80/-90|-45/-15|-27/-9|0/-7|20/-7',
      'loudnorm=I=-16:TP=-1.5:LRA=11',
    ].join(',');

    final command = [
      '-y', '-hide_banner',
      '-i', _quote(asset.path),
      '-vn',
      '-af', filters,
      '-c:a', 'aac', '-b:a', '192k',
      _quote(output),
    ].join(' ');

    final result = await _ffmpeg.run(
      command,
      totalDuration: asset.duration,
      onProgress: onProgress,
    );
    return result.map((_) => output);
  }

  // ── Helpers ────────────────────────────────────────────────────────

  Future<Result<File>> _extractSpeechAudio(MediaAsset asset) async {
    final output = File(p.join(_paths.tempDir.path, 'speech_${asset.id}.m4a'));
    await output.parent.create(recursive: true);

    final command = [
      '-y', '-hide_banner',
      '-i', _quote(asset.path),
      '-vn', '-ac', '1', '-ar', '16000',
      '-c:a', 'aac', '-b:a', '64k',
      _quote(output.path),
    ].join(' ');

    final result = await _ffmpeg.run(command);
    if (result.isErr) return Result.err(result.failureOrNull!);
    if (!await output.exists()) {
      return const Result.err(
        UnsupportedMediaFailure('That clip has no audio to caption.'),
      );
    }
    return Result.ok(output);
  }

  static Map<String, double> _parseSignalStats(String log) {
    final stats = <String, double>{};
    final pattern = RegExp(r'lavfi\.signalstats\.(\w+)=([\d.\-]+)');
    for (final match in pattern.allMatches(log)) {
      final value = double.tryParse(match.group(2) ?? '');
      if (value != null) stats[match.group(1)!.toUpperCase()] = value;
    }
    return stats;
  }

  static String _quote(String value) =>
      value.contains(' ') ? '"$value"' : value;
}

/// Pluggable inference backend for the model-driven features.
///
/// The shape is deliberately transport-agnostic: today it is an HTTP endpoint
/// the user points at their own server, but the same interface fits an
/// on-device runtime (TFLite/ONNX) if models are bundled in a later build.
abstract interface class AiBackend {
  Future<bool> isReachable();
  Future<Set<AiCapability>> capabilities();

  Future<Result<SubtitleTrack>> transcribe({
    required File audioFile,
    String? languageHint,
    void Function(double progress)? onProgress,
  });

  Future<Result<String>> matte({
    required String videoPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  });

  Future<Result<TrackingResult>> track({
    required String videoPath,
    required double x,
    required double y,
    required double width,
    required double height,
    required Duration from,
    required Duration to,
    void Function(double progress)? onProgress,
  });

  Future<Result<List<TrackingResult>>> trackFaces({
    required String videoPath,
    required Duration from,
    required Duration to,
    void Function(double progress)? onProgress,
  });

  Future<Result<String>> speech({
    required String text,
    required String voice,
    required String outputPath,
    void Function(double progress)? onProgress,
  });
}

/// Parses the wire format the backends share, so an implementation only has to
/// deal with transport.
abstract final class AiWireFormat {
  static SubtitleTrack subtitlesFromJson(Map<String, dynamic> json) {
    final segments = (json['segments'] as List?) ?? const [];
    return SubtitleTrack(
      language: json['language'] as String? ?? 'en',
      cues: segments.map((raw) {
        final map = (raw as Map).cast<String, dynamic>();
        return SubtitleCue(
          start: _seconds(map['start']),
          end: _seconds(map['end']),
          text: (map['text'] as String? ?? '').trim(),
          confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
          words: [
            for (final w in (map['words'] as List?) ?? const [])
              WordTiming(
                start: _seconds((w as Map)['start']),
                end: _seconds(w['end']),
                text: ((w['word'] ?? w['text']) as String? ?? '').trim(),
              ),
          ],
        );
      }).where((c) => c.text.isNotEmpty).toList(),
    );
  }

  static TrackingResult trackingFromJson(Map<String, dynamic> json) =>
      TrackingResult(
        label: json['label'] as String?,
        points: ((json['points'] as List?) ?? const []).map((raw) {
          final map = (raw as Map).cast<String, dynamic>();
          return TrackedPoint(
            time: _seconds(map['t']),
            x: (map['x'] as num?)?.toDouble() ?? 0,
            y: (map['y'] as num?)?.toDouble() ?? 0,
            width: (map['w'] as num?)?.toDouble() ?? 0,
            height: (map['h'] as num?)?.toDouble() ?? 0,
            confidence: (map['c'] as num?)?.toDouble() ?? 1,
          );
        }).toList(),
      );

  static String encodeRequest(Map<String, dynamic> body) => jsonEncode(body);

  static Duration _seconds(Object? value) {
    final seconds = value is num ? value.toDouble() : 0.0;
    return Duration(microseconds: (seconds * 1e6).round());
  }

  const AiWireFormat._();
}
