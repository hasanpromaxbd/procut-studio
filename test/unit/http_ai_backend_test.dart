/// The HTTP AI backend.
///
/// Runs against a real local HTTP server rather than a mocked Dio, so the
/// multipart encoding, response parsing and error mapping are all exercised
/// end to end — a mock would happily accept a request shape no Whisper server
/// would.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/data/datasources/remote/http_ai_backend.dart';
import 'package:procut_studio/domain/repositories/ai_repository.dart';

/// Minimal stand-in for an OpenAI-compatible speech server.
class _FakeServer {
  _FakeServer(this._handler);

  final FutureOr<void> Function(HttpRequest request) _handler;
  late final HttpServer _server;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.forEach((request) async {
      await _handler(request);
      await request.response.close();
    }));
    return 'http://${_server.address.address}:${_server.port}/v1';
  }

  Future<void> stop() => _server.close(force: true);
}

const _verboseJson = {
  'language': 'en',
  'segments': [
    {'start': 0.0, 'end': 1.5, 'text': ' Hello there', 'confidence': 0.95},
    {'start': 1.5, 'end': 3.0, 'text': ' second line', 'confidence': 0.6},
    {'start': 3.0, 'end': 3.2, 'text': '   ', 'confidence': 0.9},
  ],
};

void main() {
  late Directory temp;
  late File audio;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ai_backend_test');
    audio = File('${temp.path}/speech.m4a')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
  });

  tearDown(() async => temp.delete(recursive: true));

  group('AiSettings', () {
    test('a trailing slash is stripped so paths do not double up', () {
      const settings = AiSettings(baseUrl: 'http://host:8000/v1///');
      expect(settings.normalised().baseUrl, 'http://host:8000/v1');
    });

    test('whitespace is trimmed from the url and key', () {
      const settings = AiSettings(baseUrl: '  http://h/v1  ', apiKey: ' k ');
      expect(settings.normalised().baseUrl, 'http://h/v1');
      expect(settings.normalised().apiKey, 'k');
    });

    test('an empty url is not configured', () {
      expect(const AiSettings().isConfigured, isFalse);
      expect(const AiSettings(baseUrl: '   ').isConfigured, isFalse);
      expect(const AiSettings(baseUrl: 'http://h').isConfigured, isTrue);
    });

    test('round-trips through JSON', () {
      const settings = AiSettings(
        baseUrl: 'http://h/v1',
        apiKey: 'secret',
        transcriptionModel: 'large-v3',
      );
      expect(AiSettings.fromJson(settings.toJson()), settings);
    });
  });

  group('transcribe', () {
    test('posts multipart and parses verbose_json segments', () async {
      String? contentType;
      String? path;

      final server = _FakeServer((request) async {
        path = request.uri.path;
        contentType = request.headers.contentType?.mimeType;
        // Drain the body so the client is not left blocked.
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_verboseJson));
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      final backend = HttpAiBackend(dio: Dio(), baseUrl: baseUrl);
      final result = await backend.transcribe(audioFile: audio);

      expect(path, '/v1/audio/transcriptions');
      expect(contentType, 'multipart/form-data');
      expect(result.isOk, isTrue);

      final track = result.unwrap();
      expect(track.language, 'en');
      // The whitespace-only third segment is dropped.
      expect(track.cues, hasLength(2));
      expect(track.cues.first.text, 'Hello there');
      expect(track.cues.first.start, Duration.zero);
      expect(track.cues.first.end, const Duration(milliseconds: 1500));
      expect(track.cues[1].isUncertain, isTrue);
    });

    test('an empty transcript is an error, not an empty caption track', () async {
      final server = _FakeServer((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'segments': <Object>[]}));
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      final result = await HttpAiBackend(dio: Dio(), baseUrl: baseUrl)
          .transcribe(audioFile: audio);

      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('No speech'));
    });

    test('reports progress and finishes at 1', () async {
      final server = _FakeServer((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_verboseJson));
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      final seen = <double>[];
      await HttpAiBackend(dio: Dio(), baseUrl: baseUrl)
          .transcribe(audioFile: audio, onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(seen.last, 1);
      // Upload progress is capped at half — inference reports nothing, and a
      // bar sitting at 100% while waiting is worse than one sitting at 50%.
      expect(seen.where((v) => v > 0.5 && v < 1), isEmpty);
    });

    test('sends the language hint when given', () async {
      var body = '';
      final server = _FakeServer((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_verboseJson));
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      await HttpAiBackend(dio: Dio(), baseUrl: baseUrl)
          .transcribe(audioFile: audio, languageHint: 'bn');

      expect(body, contains('bn'));
      expect(body, contains('verbose_json'));
    });
  });

  group('error mapping', () {
    Future<String> messageForStatus(int status) async {
      final server = _FakeServer((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      final result = await HttpAiBackend(dio: Dio(), baseUrl: baseUrl)
          .transcribe(audioFile: audio);
      return result.failureOrNull!.message;
    }

    test('401 blames the API key', () async {
      expect(await messageForStatus(401), contains('API key'));
    });

    test('404 says the feature is not implemented', () async {
      expect(await messageForStatus(404), contains('does not implement'));
    });

    test('413 says the clip is too large', () async {
      expect(await messageForStatus(413), contains('too large'));
    });

    test('500 blames the server, not the user', () async {
      expect(await messageForStatus(500), contains('internal error'));
    });

    test('an unreachable host names the address and the likely cause', () async {
      // Port 1 is reserved and refuses instantly.
      final backend = HttpAiBackend(
        dio: Dio(),
        baseUrl: 'http://127.0.0.1:1/v1',
      );
      final result = await backend.transcribe(audioFile: audio);

      expect(result.isErr, isTrue);
      final message = result.failureOrNull!.message;
      expect(message, contains('127.0.0.1:1'));
      expect(message, contains('same network'));
    });
  });

  group('reachability and capabilities', () {
    test('isReachable is true when /models answers', () async {
      final server = _FakeServer((request) async {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'data': <Object>[]}));
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      expect(
        await HttpAiBackend(dio: Dio(), baseUrl: baseUrl).isReachable(),
        isTrue,
      );
    });

    test('isReachable is false when nothing is listening', () async {
      expect(
        await HttpAiBackend(dio: Dio(), baseUrl: 'http://127.0.0.1:1/v1')
            .isReachable(),
        isFalse,
      );
    });

    test('capabilities offers only endpoints that exist', () async {
      // Whisper-only deployment: /matte and /track are absent.
      final server = _FakeServer((request) async {
        await request.drain<void>();
        request.response.statusCode =
            request.uri.path == '/v1/models' ? 200 : 404;
      });
      final baseUrl = await server.start();
      addTearDown(server.stop);

      final capabilities =
          await HttpAiBackend(dio: Dio(), baseUrl: baseUrl).capabilities();

      expect(capabilities, contains(AiCapability.autoCaption));
      expect(capabilities, isNot(contains(AiCapability.backgroundRemoval)));
      expect(capabilities, isNot(contains(AiCapability.objectTracking)));
    });

    test('an unreachable backend advertises nothing', () async {
      final capabilities =
          await HttpAiBackend(dio: Dio(), baseUrl: 'http://127.0.0.1:1/v1')
              .capabilities();
      expect(capabilities, isEmpty);
    });
  });
}
