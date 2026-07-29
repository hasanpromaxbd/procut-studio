/// Renders text and sticker layers to PNG for the export pipeline.
///
/// The alternative — FFmpeg's `drawtext` — cannot do gradient fills, per-glyph
/// animation or Google Fonts, and would give a different result from the
/// preview. Rasterising through Flutter costs one PNG per frame for animated
/// layers, which is cheap next to the encode itself and guarantees the export
/// matches what the user composed.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/project.dart';
import '../export/render_plan.dart';
import 'layer_painter.dart';

class LayerRasteriser {
  const LayerRasteriser();

  static const _log = Log('LayerRasteriser');

  Future<Result<void>> rasterise({
    required Project project,
    required RasterStep step,
    required int canvasWidth,
    required int canvasHeight,
    required int fps,
  }) async {
    final found = project.timeline.findClip(step.clipId);
    if (found == null) {
      return Result.err(
        InvalidEditFailure('Layer ${step.clipId} vanished before rendering.'),
      );
    }
    final clip = found.$2;

    await _ensureStickerImages(clip);

    try {
      if (!step.isSequence) {
        final bytes = await _renderFrame(
          clip: clip,
          localTime: Duration.zero,
          width: canvasWidth,
          height: canvasHeight,
        );
        await File(step.outputPath).writeAsBytes(bytes, flush: true);
        return const Result.ok(null);
      }

      final dir = Directory(step.outputPath);
      if (!await dir.exists()) await dir.create(recursive: true);

      final frameInterval = Duration(microseconds: (1e6 / fps).round());
      for (var frame = 0; frame < step.frameCount; frame++) {
        final bytes = await _renderFrame(
          clip: clip,
          localTime: frameInterval * frame,
          width: canvasWidth,
          height: canvasHeight,
        );
        // FFmpeg's image2 demuxer indexes from 1, and `%05d` must match the
        // pattern registered as the input.
        final name = '${(frame + 1).toString().padLeft(5, '0')}.png';
        await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
      }

      _log.d(
        'rasterised layer',
        fields: {'clip': step.clipId, 'frames': step.frameCount},
      );
      return const Result.ok(null);
    } catch (e, s) {
      _log.e('raster failed', error: e, stackTrace: s);
      return Result.err(
        UnknownFailure(
          'Could not render a text or sticker layer.',
          cause: e,
          stackTrace: s,
        ),
      );
    }
  }

  Future<Uint8List> _renderFrame({
    required Clip clip,
    required Duration localTime,
    required int width,
    required int height,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    LayerPainter.paintClip(
      canvas: canvas,
      size: Size(width.toDouble(), height.toDouble()),
      clip: clip,
      localTime: localTime,
    );

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Layer encoded to zero bytes');
        }
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  /// Decodes any sticker bitmaps the painter will need. The painter is
  /// synchronous, so this has to happen first.
  Future<void> _ensureStickerImages(Clip clip) async {
    if (clip is! StickerClip) return;
    final path = clip.assetPath;
    if (path == null || path.isEmpty) return;
    if (StickerImageCache.contains(path)) return;

    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    StickerImageCache.put(path, frame.image);
  }
}
