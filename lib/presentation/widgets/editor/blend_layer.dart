/// Composites a subtree with a blend mode.
///
/// Flutter has no widget for this: `ColorFiltered` blends against a *colour*,
/// not against what is already painted. The only way to blend a subtree with
/// the layers beneath it is to paint it into its own layer with a blend mode
/// on the paint — which is what `saveLayer` does, and what this wraps.
///
/// `saveLayer` is not free: it allocates an offscreen buffer the size of the
/// child. That is why it is only used when a clip actually asks for a blend
/// mode, and why the default path never touches it.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../domain/entities/transform2d.dart';

class BlendLayer extends SingleChildRenderObjectWidget {
  const BlendLayer({required this.mode, required super.child, super.key});

  final LayerBlendMode mode;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlendLayer(mode.toBlendMode());

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBlendLayer).blendMode = mode.toBlendMode();
  }
}

class _RenderBlendLayer extends RenderProxyBox {
  _RenderBlendLayer(this._blendMode);

  BlendMode _blendMode;

  set blendMode(BlendMode value) {
    if (_blendMode == value) return;
    _blendMode = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    context.canvas.saveLayer(offset & size, Paint()..blendMode = _blendMode);
    super.paint(context, offset);
    context.canvas.restore();
  }
}

extension BlendModeMapping on LayerBlendMode {
  /// The Flutter equivalent of each FFmpeg mode.
  ///
  /// `addition` maps to `plus`, which is the same operation under a different
  /// name; the rest line up one to one.
  BlendMode toBlendMode() => switch (this) {
    LayerBlendMode.normal => BlendMode.srcOver,
    LayerBlendMode.multiply => BlendMode.multiply,
    LayerBlendMode.screen => BlendMode.screen,
    LayerBlendMode.overlay => BlendMode.overlay,
    LayerBlendMode.darken => BlendMode.darken,
    LayerBlendMode.lighten => BlendMode.lighten,
    LayerBlendMode.difference => BlendMode.difference,
    LayerBlendMode.addition => BlendMode.plus,
  };
}
