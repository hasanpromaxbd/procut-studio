/// Entry point and startup sequence.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/di/providers.dart';
import 'core/logging/app_logger.dart';
import 'core/services/path_service.dart';
import 'data/datasources/local/hive_store.dart';
import 'engine/ffmpeg/ffmpeg_service.dart';
import 'engine/render/shader_library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHandlers();

  const log = Log('Bootstrap');
  final stopwatch = Stopwatch()..start();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // ── Infrastructure that must exist before the first frame ───────────
  final paths = PathService();
  await paths.init();

  final store = HiveStore();
  final opened = await store.init();
  if (opened.isErr) {
    log.e('database unavailable: ${opened.failureOrNull?.message}');
    runApp(_StartupFailure(message: opened.failureOrNull!.message));
    return;
  }

  final ffmpeg = FFmpegService();
  await ffmpeg.configure();

  final shaders = ShaderLibrary();
  await shaders.warmUp();

  // Clean up anything a previous crash left behind. Not awaited — a slow
  // filesystem must not delay the first frame.
  unawaited(paths.reapOrphanedWorkspaces());

  stopwatch.stop();
  log.i('startup complete', fields: {'ms': stopwatch.elapsedMilliseconds});

  runApp(
    ProviderScope(
      overrides: [
        pathServiceProvider.overrideWithValue(paths),
        hiveStoreProvider.overrideWithValue(store),
        shaderLibraryProvider.overrideWithValue(shaders),
        ffmpegServiceProvider.overrideWithValue(ffmpeg),
      ],
      child: const ProCutApp(),
    ),
  );
}

/// Shown when the app cannot start at all — a corrupt database being the only
/// realistic cause. Better than a blank screen or a crash loop.
class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline_rounded, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'ProCut Studio could not start',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
