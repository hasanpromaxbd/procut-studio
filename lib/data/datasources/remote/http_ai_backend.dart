/// Concrete [AiBackend] over HTTP.
///
/// Targets the **OpenAI-compatible** shape, because that is what the
/// self-hostable speech servers already speak — faster-whisper-server,
/// speaches, whisper.cpp's server, vLLM. Pointing this at
/// `http://your-host:8000/v1` is the whole configuration.
///
/// The matte and tracking endpoints have no comparable standard, so those use a
/// small documented contract of our own (see the method docs). They are
/// deliberately separate calls rather than one overloaded endpoint so a
/// deployment can implement only what it has models for — `capabilities()`
/// reports what actually answered.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/failure.dart';
import '../../../core/error/result.dart';
import '../../../core/logging/app_logger.dart';
import '../../../domain/entities/subtitle.dart';
import '../../../domain/repositories/ai_repository.dart';
import '../../../engine/ai/ai_service.dart';

/// Everything needed to reach a backend. Lives here rather than in the
/// presentation layer so the DI graph can read it without depending upward.
@immutable
class AiSettings {
  const AiSettings({
    this.baseUrl = '',
    this.apiKey = '',
    this.transcriptionModel = 'whisper-1',
    this.speechModel = 'tts-1',
  });

  final String baseUrl;
  final String apiKey;
  final String transcriptionModel;
  final String speechModel;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  AiSettings copyWith({
    String? baseUrl,
    String? apiKey,
    String? transcriptionModel,
    String? speechModel,
  }) => AiSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    transcriptionModel: transcriptionModel ?? this.transcriptionModel,
    speechModel: speechModel ?? this.speechModel,
  );

  /// Trailing slashes turn every request path into a double slash, which some
  /// servers 404 — normalised once, here, rather than at each call site.
  AiSettings normalised() => copyWith(
    baseUrl: baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    apiKey: apiKey.trim(),
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': transcriptionModel,
    'speechModel': speechModel,
  };

  factory AiSettings.fromJson(Map<String, dynamic> json) => AiSettings(
    baseUrl: json['baseUrl'] as String? ?? '',
    apiKey: json['apiKey'] as String? ?? '',
    transcriptionModel: json['model'] as String? ?? 'whisper-1',
    speechModel: json['speechModel'] as String? ?? 'tts-1',
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiSettings &&
          other.baseUrl == baseUrl &&
          other.apiKey == apiKey &&
          other.transcriptionModel == transcriptionModel;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, transcriptionModel);
}

class HttpAiBackend implements AiBackend {
  HttpAiBackend({
    required Dio dio,
    required this.baseUrl,
    this.apiKey,
    this.transcriptionModel = 'whisper-1',
    this.speechModel = 'tts-1',
  }) : _dio = dio;

  static const _log = Log('HttpAiBackend');

  final Dio _dio;

  /// e.g. `http://192.168.10.5:8000/v1`
  final String baseUrl;

  /// Sent as a bearer token when set. Most self-hosted servers ignore it.
  final String? apiKey;

  final String transcriptionModel;
  final String speechModel;

  Options get _options => Options(
    headers: {if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
    sendTimeout: const Duration(minutes: 5),
    receiveTimeout: const Duration(minutes: 10),
  );

  Set<AiCapability>? _cachedCapabilities;

  @override
  Future<bool> isReachable() async {
    try {
      // `/models` is the OpenAI-compatible health check every one of these
      // servers implements, so it doubles as a reachability probe.
      final response = await _dio.get<Object?>(
        '$baseUrl/models',
        options: Options(
          headers: _options.headers,
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      return response.statusCode != null && response.statusCode! < 400;
    } on DioException catch (e) {
      _log.d('backend unreachable: ${e.type}');
      return false;
    }
  }

  @override
  Future<Set<AiCapability>> capabilities() async {
    if (_cachedCapabilities != null) return _cachedCapabilities!;
    if (!await isReachable()) return const {};

    // Transcription is assumed present on any OpenAI-compatible server. The
    // rest are probed, so a deployment that only runs Whisper does not offer
    // the user a background-removal button that will fail.
    final available = <AiCapability>{AiCapability.autoCaption};

    for (final entry in const {
      '/matte': AiCapability.backgroundRemoval,
      '/track': AiCapability.objectTracking,
      '/track/faces': AiCapability.faceTracking,
      '/audio/speech': AiCapability.textToSpeech,
    }.entries) {
      if (await _endpointExists(entry.key)) available.add(entry.value);
    }

    _log.i('backend capabilities', fields: {'count': available.length});
    return _cachedCapabilities = available;
  }

  Future<bool> _endpointExists(String path) async {
    try {
      final response = await _dio.request<Object?>(
        '$baseUrl$path',
        options: Options(
          method: 'OPTIONS',
          headers: _options.headers,
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 6),
          validateStatus: (code) => code != null,
        ),
      );
      // 404/501 means not implemented; anything else means something is there.
      return response.statusCode != 404 && response.statusCode != 501;
    } on DioException {
      return false;
    }
  }

  @override
  Future<Result<SubtitleTrack>> transcribe({
    required File audioFile,
    String? languageHint,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(audioFile.path),
        'model': transcriptionModel,
        // Plain `json` returns only the full text; `verbose_json` is what
        // carries per-segment timings, which is the entire point here.
        'response_format': 'verbose_json',
        // Word-level timestamps power karaoke captions. Servers that do not
        // support the flag ignore it and return segments only, which still
        // works — the captions just cannot highlight per word.
        'timestamp_granularities[]': 'word',
        'language': ?languageHint,
      });

      final response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/audio/transcriptions',
        data: form,
        options: _options,
        onSendProgress: (sent, total) {
          // Upload is the only phase with real progress; inference gives none,
          // so it is capped at half to avoid a bar that sits at 100% waiting.
          if (total > 0) onProgress?.call((sent / total) * 0.5);
        },
      );

      final data = response.data;
      if (data == null) {
        return const Result.err(
          NetworkFailure('The transcription server returned nothing.'),
        );
      }

      onProgress?.call(1);
      final track = AiWireFormat.subtitlesFromJson(data);

      if (track.isEmpty) {
        return const Result.err(
          UnsupportedMediaFailure('No speech was found in that clip.'),
        );
      }
      _log.i('transcribed', fields: {'cues': track.cues.length});
      return Result.ok(track);
    } on DioException catch (e) {
      return Result.err(_networkFailure(e, 'Transcription failed.'));
    } catch (e, s) {
      _log.e('transcribe threw', error: e, stackTrace: s);
      return Result.err(
        UnknownFailure('Transcription failed.', cause: e, stackTrace: s),
      );
    }
  }

  /// `POST /audio/speech` — the OpenAI TTS shape, which speaches and
  /// openedai-speech both serve. The response body is the audio itself.
  @override
  Future<Result<String>> speech({
    required String text,
    required String voice,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final response = await _dio.post<List<int>>(
        '$baseUrl/audio/speech',
        data: {
          'model': speechModel,
          'input': text,
          'voice': voice,
          // WAV imports without a decode step and the file never leaves the
          // device, so compression buys nothing here.
          'response_format': 'wav',
        },
        options: _options.copyWith(responseType: ResponseType.bytes),
        onReceiveProgress: (got, total) {
          if (total > 0) onProgress?.call(got / total);
        },
      );

      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return const Result.err(
          NetworkFailure('The speech server returned no audio.'),
        );
      }
      await File(outputPath).writeAsBytes(bytes);
      _log.i('speech synthesised', fields: {
        'chars': text.length,
        'bytes': bytes.length,
      });
      return Result.ok(outputPath);
    } on DioException catch (e) {
      return Result.err(_networkFailure(e, 'Voiceover failed.'));
    } catch (e, s) {
      return Result.err(
        UnknownFailure('Voiceover failed.', cause: e, stackTrace: s),
      );
    }
  }

  /// `POST /matte` with the video as multipart, expecting an alpha-matte video
  /// back as a binary body.
  @override
  Future<Result<String>> matte({
    required String videoPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(videoPath),
      });

      await _dio.download(
        '$baseUrl/matte',
        outputPath,
        data: form,
        options: Options(method: 'POST', headers: _options.headers),
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
      return Result.ok(outputPath);
    } on DioException catch (e) {
      return Result.err(_networkFailure(e, 'Background removal failed.'));
    }
  }

  /// `POST /track` with a normalised seed box, expecting
  /// `{"label": …, "points": [{"t": s, "x": …, "y": …, "w": …, "h": …, "c": …}]}`.
  @override
  Future<Result<TrackingResult>> track({
    required String videoPath,
    required double x,
    required double y,
    required double width,
    required double height,
    required Duration from,
    required Duration to,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(videoPath),
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'from': from.inMicroseconds / 1e6,
        'to': to.inMicroseconds / 1e6,
      });

      final response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/track',
        data: form,
        options: _options,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call((sent / total) * 0.5);
        },
      );

      final data = response.data;
      if (data == null) {
        return const Result.err(
          NetworkFailure('The tracking server returned nothing.'),
        );
      }
      onProgress?.call(1);
      return Result.ok(AiWireFormat.trackingFromJson(data));
    } on DioException catch (e) {
      return Result.err(_networkFailure(e, 'Object tracking failed.'));
    }
  }

  /// `POST /track/faces`, expecting `{"tracks": [ <same shape as /track> ]}`.
  @override
  Future<Result<List<TrackingResult>>> trackFaces({
    required String videoPath,
    required Duration from,
    required Duration to,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(videoPath),
        'from': from.inMicroseconds / 1e6,
        'to': to.inMicroseconds / 1e6,
      });

      final response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/track/faces',
        data: form,
        options: _options,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call((sent / total) * 0.5);
        },
      );

      final tracks = (response.data?['tracks'] as List?) ?? const [];
      onProgress?.call(1);
      return Result.ok(
        tracks
            .map(
              (t) => AiWireFormat.trackingFromJson(
                (t as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
    } on DioException catch (e) {
      return Result.err(_networkFailure(e, 'Face tracking failed.'));
    }
  }

  Failure _networkFailure(DioException e, String fallback) {
    final status = e.response?.statusCode;

    // These are the failures a self-hosting user will actually hit, and each
    // has a different fix — so each gets its own sentence rather than one
    // generic "request failed".
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError =>
        'Could not reach the AI server at $baseUrl. Check it is running and '
            'that this device is on the same network.',
      DioExceptionType.receiveTimeout =>
        'The AI server took too long. A long clip may need a bigger timeout '
            'or a faster model.',
      _ => switch (status) {
        401 || 403 => 'The AI server rejected the API key.',
        404 => 'The AI server does not implement this feature.',
        413 => 'That clip is too large for the AI server to accept.',
        final int code when code >= 500 => 'The AI server hit an internal error.',
        _ => fallback,
      },
    };

    _log.w('ai request failed', fields: {'type': e.type.name, 'status': status});
    return NetworkFailure(message, statusCode: status, cause: e);
  }
}
