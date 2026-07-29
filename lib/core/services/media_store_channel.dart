/// Platform bridge for publishing a finished render to the device gallery.
///
/// Android 10+ scoped storage forbids writing into `DCIM/` or `Movies/`
/// directly. The file has to be handed to MediaStore, which returns a content
/// URI. The Kotlin side lives in
/// `android/app/src/main/kotlin/.../MainActivity.kt`.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../error/failure.dart';
import '../error/result.dart';
import '../logging/app_logger.dart';

abstract final class AndroidMediaStoreChannel {
  static const MethodChannel _channel = MethodChannel(
    'com.procutstudio.procut_studio/mediastore',
  );

  static const _log = Log('MediaStoreChannel');

  /// Copies [filePath] into `Movies/ProCut Studio/` via MediaStore and returns
  /// the resulting content URI, or null if the platform refused.
  static Future<String?> insertVideo({
    required String filePath,
    required String displayName,
    String relativeDirectory = 'Movies/ProCut Studio',
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('insertVideo', {
        'filePath': filePath,
        'displayName': displayName,
        'relativePath': relativeDirectory,
      });
    } on PlatformException catch (e) {
      _log.e('insertVideo failed', error: e, fields: {'code': e.code});
      return null;
    } on MissingPluginException {
      // Running in a test harness or on a platform without the native side.
      _log.w('mediastore channel unavailable');
      return null;
    }
  }

  const AndroidMediaStoreChannel._();
}

abstract final class SharePublisher {
  static const _log = Log('Share');

  static Future<Result<void>> share(String filePath, {String? subject}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return Result.err(
          UnsupportedMediaFailure('That file no longer exists.', path: filePath),
        );
      }
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          subject: subject,
          text: subject,
        ),
      );
      _log.d('share result: ${result.status}');
      return const Result.ok(null);
    } catch (e, s) {
      _log.e('share failed', error: e, stackTrace: s);
      return Result.err(
        UnknownFailure('Could not open the share sheet.', cause: e, stackTrace: s),
      );
    }
  }

  const SharePublisher._();
}
