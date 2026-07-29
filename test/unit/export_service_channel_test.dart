/// The export foreground-service bridge.
///
/// The native side cannot be exercised here, so these tests pin the contract:
/// the exact method names and argument shapes `ExportService.kt` reads, and the
/// rule that a notification failure never disturbs a running export.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/services/export_service_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.procutstudio.procut_studio/export_service';
  const channel = MethodChannel(channelName);

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('outbound calls', () {
    test('start sends the title and message the service reads', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await bridge.start(title: 'Exporting "Trip"', message: 'Preparing');

      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {
        'title': 'Exporting "Trip"',
        'message': 'Preparing',
      });
    });

    test('update clamps progress into 0..100', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await bridge.update(message: 'Encoding', progress: 140);
      await bridge.update(message: 'Encoding', progress: -20);

      expect(calls[0].arguments['progress'], 100);
      expect(calls[1].arguments['progress'], 0);
    });

    test('update carries the indeterminate flag', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await bridge.update(
        message: 'Preparing',
        progress: 0,
        indeterminate: true,
      );

      expect(calls.single.arguments['indeterminate'], isTrue);
    });

    test('stop takes no arguments', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await bridge.stop();

      expect(calls.single.method, 'stop');
    });
  });

  group('resilience', () {
    test('a platform failure does not throw into the export', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'BOOM');
          });

      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      // A notification that cannot be posted must never abort a render.
      await expectLater(
        bridge.update(message: 'Encoding', progress: 50),
        completes,
      );
    });

    test('a missing native side is tolerated', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await expectLater(bridge.start(title: 'x', message: 'y'), completes);
    });
  });

  group('inbound cancel', () {
    test('a notification Cancel tap surfaces on the stream', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      final received = expectLater(bridge.cancelRequests.first, completes);

      // Simulate the native side invoking the Dart handler.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onCancelRequested'),
            ),
            (_) {},
          );

      await received;
    });

    test('an unknown native method is ignored rather than throwing', () async {
      final bridge = ExportServiceChannel(isSupported: true);
      addTearDown(bridge.dispose);

      await expectLater(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channelName,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('somethingElse'),
              ),
              (_) {},
            ),
        completes,
      );
    });
  });
}
