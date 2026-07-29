/// Bridge to the Android foreground service that keeps a render alive.
///
/// FFmpeg runs inside the Flutter process, so this does not move the encode
/// anywhere — it promotes the process to foreground importance, which is what
/// stops Android reclaiming it while the user is in another app or the screen
/// is off. See `ExportService.kt` for the full picture, including what it
/// deliberately does not protect against.
///
/// Every method is a no-op off Android and a no-op when the native side is
/// missing, so the export path never has to branch on platform.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

class ExportServiceChannel {
  ExportServiceChannel({MethodChannel? channel, bool? isSupported})
    : _channel = channel ??
          const MethodChannel('com.procutstudio.procut_studio/export_service'),
      // Injectable so the contract can be tested on a host machine. The
      // default is the real answer: no other platform has this service.
      _supported = isSupported ?? Platform.isAndroid {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const _log = Log('ExportServiceChannel');

  final MethodChannel _channel;
  final bool _supported;

  final StreamController<void> _cancelRequests =
      StreamController<void>.broadcast();

  /// Emits when the user taps Cancel on the export notification.
  Stream<void> get cancelRequests => _cancelRequests.stream;

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onCancelRequested') {
      _log.i('cancel requested from notification');
      if (!_cancelRequests.isClosed) _cancelRequests.add(null);
    }
  }

  Future<void> start({required String title, required String message}) =>
      _invoke('start', {'title': title, 'message': message});

  Future<void> update({
    required String message,
    required int progress,
    bool indeterminate = false,
  }) => _invoke('update', {
    'message': message,
    'progress': progress.clamp(0, 100),
    'indeterminate': indeterminate,
  });

  Future<void> stop() => _invoke('stop', const {});

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (e) {
      // A failed notification must never take down a running export.
      _log.w('export service $method failed', error: e);
    } on MissingPluginException {
      // Test harness, or a build without the native side.
      _log.d('export service channel unavailable');
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _cancelRequests.close();
  }
}
