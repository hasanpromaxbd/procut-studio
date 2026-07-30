/// The Bdrive client, against a local server speaking NimbusDrive's protocol.
///
/// The fake below implements the same endpoints with the same bodies the real
/// backend serves (read from its source), so these tests catch a drifting
/// request shape — the failure a mocked Dio can never see.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/data/datasources/remote/bdrive_client.dart';

class _FakeBdrive {
  late final HttpServer _server;

  final Map<String, List<int>> uploads = {};
  final Map<String, int> uploadSizes = {};
  final List<String> folderNames = [];
  Map<String, dynamic>? lastLoginBody;
  bool twoFactor = false;
  bool folderExists = false;

  /// Fails the first chunk PUT with a 500, to force the resume path.
  bool failFirstChunk = false;
  var _chunkPuts = 0;

  static const chunkSize = 1024;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.forEach(_handle));
    return 'http://${_server.address.address}:${_server.port}';
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;

    void json(Object body, {int code = 200}) {
      response.statusCode = code;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
    }

    if (path == '/v1/auth/login') {
      lastLoginBody = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      if (twoFactor) {
        json({'twoFactorRequired': true, 'challengeToken': 'c'});
      } else {
        json({
          'user': {'id': 'u1'},
          'tokens': {
            'accessToken': 'token123',
            'refreshToken': 'r',
            'tokenType': 'Bearer',
            'expiresIn': 900,
          },
        });
      }
    } else if (path == '/v1/entries') {
      json({
        'folder': null,
        'breadcrumb': const <Object>[],
        'entries': [
          if (folderExists)
            {'type': 'folder', 'id': 'existing', 'name': 'ProCut Backups'},
          {'type': 'file', 'id': 'f9', 'name': 'unrelated.mp4'},
        ],
      });
    } else if (path == '/v1/folders') {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      folderNames.add(body['name'] as String);
      json({
        'folder': {'type': 'folder', 'id': 'fold1', 'name': body['name']},
      }, code: 201);
    } else if (path == '/v1/uploads' && request.method == 'POST') {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      const id = 'up1';
      uploads[id] = [];
      uploadSizes[id] = body['sizeBytes'] as int;
      json({'uploadId': id, 'offset': 0, 'chunkSize': chunkSize}, code: 201);
    } else if (path.startsWith('/v1/uploads/') && request.method == 'PUT') {
      _chunkPuts++;
      final id = path.split('/')[3];
      final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      if (failFirstChunk && _chunkPuts == 1) {
        // Pretend the chunk landed but the response was lost — the resume
        // must pick up from the server's offset, not resend.
        uploads[id]!.addAll(bytes);
        json({'error': {'code': 'FLAKY', 'message': 'try again'}}, code: 500);
      } else {
        final offset = int.parse(request.uri.queryParameters['offset']!);
        expect(offset, uploads[id]!.length,
            reason: 'chunks must arrive in order at the stored offset');
        uploads[id]!.addAll(bytes);
        json({
          'offset': uploads[id]!.length,
          'complete': uploads[id]!.length == uploadSizes[id],
        });
      }
    } else if (path.endsWith('/complete')) {
      json({
        'file': {'type': 'file', 'id': 'file42', 'name': 'b.zip'},
      }, code: 201);
    } else if (path.startsWith('/v1/uploads/') && request.method == 'GET') {
      final id = path.split('/')[3];
      json({
        'offset': uploads[id]!.length,
        'size': uploadSizes[id],
        'status': 'active',
      });
    } else {
      json({'error': {'code': 'NOT_FOUND', 'message': 'no such route'}},
          code: 404);
    }
    await response.close();
  }
}

BdriveClient _client(String base) => BdriveClient(
  dio: Dio(),
  settings: BdriveSettings(
    serverUrl: base,
    email: 'hasan@example.com',
    password: 'pw',
  ),
);

File _bundle(int bytes) {
  final file = File(
    '${Directory.systemTemp.createTempSync('bdrive').path}/backup.zip',
  );
  file.writeAsBytesSync(List.generate(bytes, (i) => i % 251));
  return file;
}

void main() {
  test('login sends the device object the schema requires', () async {
    final server = _FakeBdrive();
    final base = await server.start();
    addTearDown(server.stop);

    final result = await _client(base).login();
    expect(result.isOk, isTrue);

    final device =
        (server.lastLoginBody!['device'] as Map).cast<String, dynamic>();
    expect(device['deviceId'], isNotEmpty);
    expect(device['platform'], 'android');
  });

  test('a 2FA account is refused with guidance, not a hang', () async {
    final server = _FakeBdrive()..twoFactor = true;
    final base = await server.start();
    addTearDown(server.stop);

    final result = await _client(base).login();
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.message, contains('two-factor'));
  });

  test('uploads chunk at the server\'s size and finalise', () async {
    final server = _FakeBdrive();
    final base = await server.start();
    addTearDown(server.stop);

    // 2.5 chunks worth, so the loop must run three times.
    final file = _bundle(_FakeBdrive.chunkSize * 2 + 512);
    final progress = <double>[];
    final result = await _client(base).uploadFile(
      file,
      onProgress: progress.add,
    );

    expect(result.valueOrNull, 'file42');
    expect(server.uploads['up1']!.length, _FakeBdrive.chunkSize * 2 + 512);
    expect(server.uploads['up1'], file.readAsBytesSync(),
        reason: 'the server must hold the exact bytes');
    expect(progress.last, 1.0);
  });

  test('reuses an existing backup folder instead of breeding copies', () async {
    final server = _FakeBdrive()..folderExists = true;
    final base = await server.start();
    addTearDown(server.stop);

    await _client(base).uploadFile(_bundle(100));
    expect(server.folderNames, isEmpty,
        reason: 'no folder may be created when one already exists');
  });

  test('a failed chunk resumes from the server offset, not from zero', () async {
    final server = _FakeBdrive()..failFirstChunk = true;
    final base = await server.start();
    addTearDown(server.stop);

    final file = _bundle(_FakeBdrive.chunkSize * 2);
    final result = await _client(base).uploadFile(file);

    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    expect(server.uploads['up1'], file.readAsBytesSync(),
        reason: 'resume must not duplicate or drop bytes');
  });
}
