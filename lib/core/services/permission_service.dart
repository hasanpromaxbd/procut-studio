/// Runtime permissions, with the Android 13 storage split handled in one place.
///
/// Android 13 (API 33) replaced `READ_EXTERNAL_STORAGE` with the granular
/// `READ_MEDIA_VIDEO` / `READ_MEDIA_AUDIO` / `READ_MEDIA_IMAGES` permissions,
/// and Android 14 added the "selected photos" partial-grant state. Callers
/// should not have to know any of that.
library;

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import '../error/failure.dart';
import '../error/result.dart';
import '../logging/app_logger.dart';

enum MediaPermissionKind { video, audio, images, microphone, notifications }

class PermissionService {
  PermissionService({DeviceSdkReader? sdkReader})
    : _sdkReader = sdkReader ?? const DeviceSdkReader();

  static const _log = Log('PermissionService');
  final DeviceSdkReader _sdkReader;

  int? _cachedSdk;

  Future<int> _sdkInt() async => _cachedSdk ??= await _sdkReader.sdkInt();

  Future<List<Permission>> _resolve(MediaPermissionKind kind) async {
    if (kind == MediaPermissionKind.microphone) return [Permission.microphone];

    // POST_NOTIFICATIONS became a runtime permission in Android 13. Below that
    // it is granted implicitly, so asking would return permanentlyDenied and
    // wrongly send the user to system settings.
    if (kind == MediaPermissionKind.notifications) {
      if (!Platform.isAndroid) return const [];
      return await _sdkInt() >= 33 ? [Permission.notification] : const [];
    }
    if (!Platform.isAndroid) return [Permission.photos];

    final sdk = await _sdkInt();
    if (sdk >= 33) {
      return switch (kind) {
        MediaPermissionKind.video => [Permission.videos],
        MediaPermissionKind.audio => [Permission.audio],
        MediaPermissionKind.images => [Permission.photos],
        MediaPermissionKind.microphone => [Permission.microphone],
        MediaPermissionKind.notifications => [Permission.notification],
      };
    }
    // API ≤ 32: one coarse storage permission covers all media types.
    return [Permission.storage];
  }

  Future<Result<void>> request(MediaPermissionKind kind) async {
    final permissions = await _resolve(kind);
    // Nothing to ask for — implicitly granted on this platform/API level.
    if (permissions.isEmpty) return const Result.ok(null);

    final statuses = <Permission, PermissionStatus>{};
    for (final permission in permissions) {
      statuses[permission] = await permission.request();
    }

    // `limited` is Android 14's partial photo grant — the user picked specific
    // items. That is a usable state for an importer, so we accept it.
    final granted = statuses.values.every(
      (s) => s.isGranted || s.isLimited || s.isProvisional,
    );
    if (granted) return const Result.ok(null);

    final permanentlyDenied =
        statuses.values.any((s) => s.isPermanentlyDenied || s.isRestricted);
    _log.w(
      'permission denied',
      fields: {'kind': kind.name, 'permanent': permanentlyDenied},
    );
    return Result.err(
      PermissionFailure(
        permanentlyDenied
            ? 'ProCut needs ${_label(kind)} access. Enable it in system settings.'
            : '${_label(kind)} access is required to continue.',
        permanentlyDenied: permanentlyDenied,
      ),
    );
  }

  Future<bool> isGranted(MediaPermissionKind kind) async {
    final permissions = await _resolve(kind);
    for (final permission in permissions) {
      final status = await permission.status;
      if (!(status.isGranted || status.isLimited || status.isProvisional)) {
        return false;
      }
    }
    return true;
  }

  /// Everything the editor needs to import and record in one prompt sequence.
  Future<Result<void>> requestEditorEssentials() async {
    for (final kind in [
      MediaPermissionKind.video,
      MediaPermissionKind.images,
      MediaPermissionKind.audio,
    ]) {
      final result = await request(kind);
      if (result.isErr) return result;
    }
    return const Result.ok(null);
  }

  Future<bool> openSettings() => openAppSettings();

  static String _label(MediaPermissionKind kind) => switch (kind) {
    MediaPermissionKind.video => 'Video',
    MediaPermissionKind.audio => 'Audio',
    MediaPermissionKind.images => 'Photo',
    MediaPermissionKind.microphone => 'Microphone',
    MediaPermissionKind.notifications => 'Notification',
  };
}

/// Indirection over the platform SDK level so tests can pin a version.
class DeviceSdkReader {
  const DeviceSdkReader();

  Future<int> sdkInt() async {
    if (!Platform.isAndroid) return 0;
    try {
      // `ro.build.version.sdk` is readable without any plugin and avoids
      // pulling device_info_plus in for a single integer.
      final result = await Process.run('getprop', ['ro.build.version.sdk']);
      final value = (result.stdout as String).trim();
      return int.tryParse(value) ?? 33;
    } catch (_) {
      return 33; // safest assumption: use the granular permissions
    }
  }
}
