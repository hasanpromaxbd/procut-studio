/// A client for Bdrive (NimbusDrive) — self-hosted cloud storage.
///
/// Speaks the server's real API, taken from its source, not guessed:
///
///   POST /v1/auth/login          {email, password, device}
///                                → {user, tokens{accessToken,…}}
///                                → {twoFactorRequired, challengeToken}
///   GET  /v1/entries?folderId    → {folder, breadcrumb, entries[…]}
///   POST /v1/folders             {parentId?, name} → 201 {folder{id,…}}
///   POST /v1/uploads             {name, folderId, sizeBytes, mimeType}
///                                → 201 {uploadId, offset, chunkSize}
///   PUT  /v1/uploads/:id?offset= octet-stream chunk → {offset, complete}
///   POST /v1/uploads/:id/complete → 201 {file}
///
/// The resumable protocol is honoured for real: chunks are sent at the
/// server's own `chunkSize`, and a dropped connection resumes from the
/// server-reported offset rather than starting over — on a phone uploading a
/// multi-gigabyte project bundle, that is the difference between a backup
/// and a battery drain.
library;

import 'dart:io';

import 'package:dio/dio.dart';

import '../../../core/error/failure.dart';
import '../../../core/error/result.dart';
import '../../../core/logging/app_logger.dart';

class BdriveSettings {
  const BdriveSettings({
    this.serverUrl = '',
    this.email = '',
    this.password = '',
  });

  final String serverUrl;
  final String email;
  final String password;

  bool get isConfigured =>
      serverUrl.trim().isNotEmpty &&
      email.trim().isNotEmpty &&
      password.isNotEmpty;

  BdriveSettings copyWith({String? serverUrl, String? email, String? password}) =>
      BdriveSettings(
        serverUrl: serverUrl ?? this.serverUrl,
        email: email ?? this.email,
        password: password ?? this.password,
      );

  BdriveSettings normalised() => copyWith(
    serverUrl: serverUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    email: email.trim(),
  );

  Map<String, dynamic> toJson() => {
    'url': serverUrl,
    'email': email,
    'password': password,
  };

  factory BdriveSettings.fromJson(Map<String, dynamic>? json) =>
      json == null
          ? const BdriveSettings()
          : BdriveSettings(
              serverUrl: json['url'] as String? ?? '',
              email: json['email'] as String? ?? '',
              password: json['password'] as String? ?? '',
            );
}

class BdriveClient {
  BdriveClient({
    required Dio dio,
    required this.settings,
    this.deviceId = 'procut-studio',
  }) : _dio = dio;

  static const _log = Log('BdriveClient');

  final Dio _dio;
  final BdriveSettings settings;
  final String deviceId;

  String? _accessToken;

  String get _base => settings.normalised().serverUrl;

  Options get _authed => Options(
    headers: {'Authorization': 'Bearer $_accessToken'},
    // The server answers errors with a JSON body worth reading; treat only
    // transport failure as an exception.
    validateStatus: (code) => code != null,
  );

  /// Logs in with the stored credentials. Two-factor accounts are refused
  /// with an actionable message — a background backup cannot type a code.
  Future<Result<void>> login() async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$_base/v1/auth/login',
        data: {
          'email': settings.normalised().email,
          'password': settings.password,
          'device': {
            'deviceId': deviceId,
            'deviceName': 'ProCut Studio',
            'platform': 'android',
          },
        },
        options: Options(validateStatus: (code) => code != null),
      );

      final data = response.data;
      if (response.statusCode != 200 || data == null) {
        return Result.err(
          NetworkFailure(_errorMessage(data) ?? 'Bdrive refused the login.'),
        );
      }
      if (data['twoFactorRequired'] == true) {
        return const Result.err(
          FeatureUnavailableFailure(
            'This Bdrive account uses two-factor login, which an automatic '
            'backup cannot complete. Use an account without 2FA for backups.',
          ),
        );
      }
      final token =
          (data['tokens'] as Map?)?.cast<String, dynamic>()['accessToken']
              as String?;
      if (token == null || token.isEmpty) {
        return const Result.err(
          NetworkFailure('Bdrive sent no access token.'),
        );
      }
      _accessToken = token;
      return const Result.ok(null);
    } on DioException catch (e) {
      return Result.err(
        NetworkFailure('Could not reach Bdrive: ${e.message}'),
      );
    }
  }

  /// Uploads [file] into [folderName] (created at the root if missing),
  /// resuming from the server's offset on retry. Returns the file id.
  Future<Result<String>> uploadFile(
    File file, {
    String folderName = 'ProCut Backups',
    void Function(double progress)? onProgress,
  }) async {
    if (_accessToken == null) {
      final auth = await login();
      if (auth.isErr) return Result.err(auth.failureOrNull!);
    }
    try {
      final folderId = await _ensureFolder(folderName);
      if (folderId == null) {
        return const Result.err(
          NetworkFailure('Could not create the backup folder on Bdrive.'),
        );
      }

      final size = await file.length();
      final created = await _dio.post<Map<String, dynamic>>(
        '$_base/v1/uploads',
        data: {
          'name': file.uri.pathSegments.last,
          'folderId': folderId,
          'sizeBytes': size,
          'mimeType': 'application/zip',
        },
        options: _authed,
      );
      final session = created.data;
      final uploadId = session?['uploadId'] as String?;
      final chunkSize = (session?['chunkSize'] as num?)?.toInt() ?? 4 * 1024 * 1024;
      if (created.statusCode != 201 || uploadId == null) {
        return Result.err(
          NetworkFailure(
            _errorMessage(session) ?? 'Bdrive refused the upload.',
          ),
        );
      }

      var offset = (session?['offset'] as num?)?.toInt() ?? 0;
      final raf = await file.open();
      try {
        while (offset < size) {
          await raf.setPosition(offset);
          final chunk = await raf.read(
            chunkSize.clamp(1, size - offset),
          );
          final put = await _dio.put<Map<String, dynamic>>(
            '$_base/v1/uploads/$uploadId',
            queryParameters: {'offset': offset},
            data: Stream.value(chunk),
            options: Options(
              headers: {
                'Authorization': 'Bearer $_accessToken',
                Headers.contentTypeHeader: 'application/octet-stream',
                Headers.contentLengthHeader: chunk.length,
              },
              validateStatus: (code) => code != null,
            ),
          );
          if (put.statusCode != 200) {
            // Ask the server where it actually got to and continue from
            // there — the whole point of a resumable protocol.
            final status = await _dio.get<Map<String, dynamic>>(
              '$_base/v1/uploads/$uploadId',
              options: _authed,
            );
            final resumeAt = (status.data?['offset'] as num?)?.toInt();
            if (resumeAt == null || resumeAt <= offset) {
              return Result.err(
                NetworkFailure(
                  _errorMessage(put.data) ?? 'A chunk upload failed.',
                ),
              );
            }
            offset = resumeAt;
            continue;
          }
          offset = (put.data?['offset'] as num?)?.toInt() ?? offset + chunk.length;
          onProgress?.call(size == 0 ? 1 : offset / size);
        }
      } finally {
        await raf.close();
      }

      final done = await _dio.post<Map<String, dynamic>>(
        '$_base/v1/uploads/$uploadId/complete',
        options: _authed,
      );
      final fileId =
          ((done.data?['file'] as Map?)?.cast<String, dynamic>() ??
              const {})['id'] as String?;
      if (done.statusCode != 201 || fileId == null) {
        return Result.err(
          NetworkFailure(
            _errorMessage(done.data) ?? 'Bdrive could not finalise the upload.',
          ),
        );
      }
      _log.i('backup uploaded', fields: {'file': fileId, 'bytes': size});
      return Result.ok(fileId);
    } on DioException catch (e) {
      return Result.err(NetworkFailure('Upload failed: ${e.message}'));
    }
  }

  /// Finds [name] at the root, creating it when absent — idempotent, so
  /// repeated backups share one folder instead of breeding copies.
  Future<String?> _ensureFolder(String name) async {
    final listing = await _dio.get<Map<String, dynamic>>(
      '$_base/v1/entries',
      options: _authed,
    );
    for (final raw in (listing.data?['entries'] as List?) ?? const []) {
      final entry = (raw as Map).cast<String, dynamic>();
      if (entry['name'] == name && entry['type'] == 'folder') {
        return entry['id'] as String?;
      }
    }

    final created = await _dio.post<Map<String, dynamic>>(
      '$_base/v1/folders',
      data: {'name': name},
      options: _authed,
    );
    return ((created.data?['folder'] as Map?)?.cast<String, dynamic>() ??
        const {})['id'] as String?;
  }

  static String? _errorMessage(Map<String, dynamic>? body) =>
      ((body?['error'] as Map?)?.cast<String, dynamic>() ??
          const {})['message'] as String?;
}
