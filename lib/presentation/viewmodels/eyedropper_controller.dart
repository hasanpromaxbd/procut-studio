/// Colour sampling from the live preview.
///
/// The preview is a stack of platform video textures, so there is no pixel
/// buffer to read directly — the only reliable way to know what the user is
/// looking at is to rasterise the composited widget and read a pixel out of it.
/// That is what the `RepaintBoundary` in `PreviewStage` exists for.
///
/// One consequence worth knowing: the sampled colour is what the *preview*
/// shows, which includes any effects already applied. For chroma key that is
/// usually what you want — you are keying the picture as graded, not the raw
/// source.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';

@immutable
class EyedropperState {
  const EyedropperState({
    this.isActive = false,
    this.targetEffectId,
    this.sampled,
  });

  final bool isActive;

  /// The effect whose key colour the next sample fills in.
  final String? targetEffectId;

  /// Last sampled colour, ARGB. Shown as a swatch after sampling.
  final int? sampled;

  EyedropperState copyWith({
    bool? isActive,
    String? targetEffectId,
    int? sampled,
    bool clearTarget = false,
  }) => EyedropperState(
    isActive: isActive ?? this.isActive,
    targetEffectId: clearTarget ? null : (targetEffectId ?? this.targetEffectId),
    sampled: sampled ?? this.sampled,
  );
}

final eyedropperProvider =
    NotifierProvider<EyedropperController, EyedropperState>(
      EyedropperController.new,
    );

class EyedropperController extends Notifier<EyedropperState> {
  static const _log = Log('Eyedropper');

  /// Key on the preview's `RepaintBoundary`, set by `PreviewStage`.
  final GlobalKey previewKey = GlobalKey();

  @override
  EyedropperState build() => const EyedropperState();

  void begin(String effectId) =>
      state = state.copyWith(isActive: true, targetEffectId: effectId);

  void cancel() =>
      state = state.copyWith(isActive: false, clearTarget: true);

  /// Samples the preview at [localPosition], in the boundary's coordinates.
  ///
  /// Returns the ARGB colour, or null when the preview could not be
  /// rasterised — which happens for a frame or two right after a layout change.
  Future<int?> sampleAt(Offset localPosition) async {
    final context = previewKey.currentContext;
    if (context == null) return null;

    final RenderObject? boundary = context.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;

    try {
      // Device pixel ratio 1: we only need the colour, and rasterising at
      // native density would allocate several megabytes for one pixel read.
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return null;

        final size = boundary.size;
        // The rasterised image can differ in size from the logical box, so map
        // the tap through the ratio rather than assuming they match.
        final x = ((localPosition.dx / size.width) * image.width)
            .round()
            .clamp(0, image.width - 1);
        final y = ((localPosition.dy / size.height) * image.height)
            .round()
            .clamp(0, image.height - 1);

        final colour = _readPixel(data.buffer.asUint8List(), image.width, x, y);
        state = state.copyWith(sampled: colour, isActive: false);
        _log.d(
          'sampled',
          fields: {'argb': colour.toRadixString(16), 'x': x, 'y': y},
        );
        return colour;
      } finally {
        image.dispose();
      }
    } catch (e) {
      _log.w('sample failed', error: e);
      return null;
    }
  }

  static int _readPixel(Uint8List rgba, int width, int x, int y) {
    final offset = (y * width + x) * 4;
    final r = rgba[offset];
    final g = rgba[offset + 1];
    final b = rgba[offset + 2];
    final a = rgba[offset + 3];
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// FFmpeg's `chromakey` wants `0xRRGGBB`; alpha is meaningless for a key.
  static String toFfmpegColour(int argb) =>
      '0x${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Rasterises the preview as a PNG — the frame exactly as composed, effects
  /// and all. [pixelRatio] upsamples the widget raster; the ceiling keeps a
  /// tablet from allocating a 100-megapixel bitmap for a screenshot.
  Future<Uint8List?> snapshotPng({double pixelRatio = 3}) async {
    final context = previewKey.currentContext;
    final boundary = context?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.size.isEmpty) {
      return null;
    }
    try {
      final image = await boundary.toImage(
        pixelRatio: pixelRatio.clamp(1, 4),
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (e) {
      _log.w('snapshot failed', error: e);
      return null;
    }
  }
}
