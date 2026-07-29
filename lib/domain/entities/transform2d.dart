/// Per-clip geometry and opacity, all keyframe-animatable.
library;

import 'package:flutter/foundation.dart';

import 'keyframe.dart';

/// Normalised crop rectangle, expressed as insets in the range 0..1 of the
/// source frame. Normalised (rather than pixel) insets survive a source being
/// swapped for a proxy at a different resolution.
@immutable
class CropRect {
  const CropRect({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  static const CropRect none = CropRect();

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isNone =>
      left == 0 && top == 0 && right == 0 && bottom == 0;

  double get width => (1 - left - right).clamp(0.0, 1.0);
  double get height => (1 - top - bottom).clamp(0.0, 1.0);

  CropRect copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) => CropRect(
    left: left ?? this.left,
    top: top ?? this.top,
    right: right ?? this.right,
    bottom: bottom ?? this.bottom,
  );

  Map<String, dynamic> toJson() => {'l': left, 't': top, 'r': right, 'b': bottom};

  factory CropRect.fromJson(Map<String, dynamic>? json) => json == null
      ? CropRect.none
      : CropRect(
          left: (json['l'] as num?)?.toDouble() ?? 0,
          top: (json['t'] as num?)?.toDouble() ?? 0,
          right: (json['r'] as num?)?.toDouble() ?? 0,
          bottom: (json['b'] as num?)?.toDouble() ?? 0,
        );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CropRect &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Blend mode for overlay layers. Values map 1:1 onto both Flutter's
/// [BlendMode] for preview and FFmpeg's `blend=all_mode=` for export.
enum LayerBlendMode {
  normal('normal'),
  multiply('multiply'),
  screen('screen'),
  overlay('overlay'),
  darken('darken'),
  lighten('lighten'),
  difference('difference'),
  addition('addition');

  const LayerBlendMode(this.id);
  final String id;

  static LayerBlendMode fromId(String? id) => LayerBlendMode.values.firstWhere(
    (e) => e.id == id,
    orElse: () => LayerBlendMode.normal,
  );

  /// FFmpeg `blend` filter mode name.
  String get ffmpegMode => switch (this) {
    LayerBlendMode.normal => 'normal',
    LayerBlendMode.multiply => 'multiply',
    LayerBlendMode.screen => 'screen',
    LayerBlendMode.overlay => 'overlay',
    LayerBlendMode.darken => 'darken',
    LayerBlendMode.lighten => 'lighten',
    LayerBlendMode.difference => 'difference',
    LayerBlendMode.addition => 'addition',
  };
}

@immutable
class Transform2D {
  const Transform2D({
    this.x = const AnimatableDouble.constant(0),
    this.y = const AnimatableDouble.constant(0),
    this.scaleX = const AnimatableDouble.constant(1),
    this.scaleY = const AnimatableDouble.constant(1),
    this.rotation = const AnimatableDouble.constant(0),
    this.opacity = const AnimatableDouble.constant(1),
    this.anchorX = 0.5,
    this.anchorY = 0.5,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.crop = CropRect.none,
    this.blendMode = LayerBlendMode.normal,
  });

  static const Transform2D identity = Transform2D();

  /// Translation as a fraction of canvas width/height, so a transform authored
  /// on a 1080×1920 project still reads correctly if the canvas is resized.
  final AnimatableDouble x;
  final AnimatableDouble y;

  final AnimatableDouble scaleX;
  final AnimatableDouble scaleY;

  /// Degrees, clockwise.
  final AnimatableDouble rotation;

  /// 0..1.
  final AnimatableDouble opacity;

  /// Rotation/scale origin as a fraction of the layer's own bounds.
  final double anchorX;
  final double anchorY;

  final bool flipHorizontal;
  final bool flipVertical;
  final CropRect crop;
  final LayerBlendMode blendMode;

  bool get isAnimated =>
      x.isAnimated ||
      y.isAnimated ||
      scaleX.isAnimated ||
      scaleY.isAnimated ||
      rotation.isAnimated ||
      opacity.isAnimated;

  /// True when nothing here changes the picture — lets the export engine skip
  /// emitting scale/rotate/overlay filters entirely for untouched clips.
  bool get isIdentity =>
      !isAnimated &&
      x.staticValue == 0 &&
      y.staticValue == 0 &&
      scaleX.staticValue == 1 &&
      scaleY.staticValue == 1 &&
      rotation.staticValue == 0 &&
      opacity.staticValue == 1 &&
      !flipHorizontal &&
      !flipVertical &&
      crop.isNone &&
      blendMode == LayerBlendMode.normal;

  /// Flattens every animated channel at [time] into plain numbers.
  ResolvedTransform resolveAt(Duration time) => ResolvedTransform(
    x: x.valueAt(time),
    y: y.valueAt(time),
    scaleX: scaleX.valueAt(time),
    scaleY: scaleY.valueAt(time),
    rotation: rotation.valueAt(time),
    opacity: opacity.valueAt(time).clamp(0.0, 1.0),
    anchorX: anchorX,
    anchorY: anchorY,
    flipHorizontal: flipHorizontal,
    flipVertical: flipVertical,
    crop: crop,
    blendMode: blendMode,
  );

  /// Drops every keyframe, keeping each channel at the value it starts on.
  ///
  /// "Remove the animation" has to mean *some* value survives; the first
  /// keyframe is the one the user set deliberately and saw on screen.
  Transform2D frozen() => copyWith(
    x: AnimatableDouble(x.valueAt(Duration.zero)),
    y: AnimatableDouble(y.valueAt(Duration.zero)),
    scaleX: AnimatableDouble(scaleX.valueAt(Duration.zero)),
    scaleY: AnimatableDouble(scaleY.valueAt(Duration.zero)),
    rotation: AnimatableDouble(rotation.valueAt(Duration.zero)),
    opacity: AnimatableDouble(opacity.valueAt(Duration.zero)),
  );

  Transform2D copyWith({
    AnimatableDouble? x,
    AnimatableDouble? y,
    AnimatableDouble? scaleX,
    AnimatableDouble? scaleY,
    AnimatableDouble? rotation,
    AnimatableDouble? opacity,
    double? anchorX,
    double? anchorY,
    bool? flipHorizontal,
    bool? flipVertical,
    CropRect? crop,
    LayerBlendMode? blendMode,
  }) => Transform2D(
    x: x ?? this.x,
    y: y ?? this.y,
    scaleX: scaleX ?? this.scaleX,
    scaleY: scaleY ?? this.scaleY,
    rotation: rotation ?? this.rotation,
    opacity: opacity ?? this.opacity,
    anchorX: anchorX ?? this.anchorX,
    anchorY: anchorY ?? this.anchorY,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    flipVertical: flipVertical ?? this.flipVertical,
    crop: crop ?? this.crop,
    blendMode: blendMode ?? this.blendMode,
  );

  /// Uniform scale helper — the UI exposes one slider for both axes unless the
  /// user unlinks them.
  Transform2D scaledUniformly(double value) => copyWith(
    scaleX: scaleX.withStatic(value),
    scaleY: scaleY.withStatic(value),
  );

  /// Shifts all animation in time — see [AnimatableDouble.shifted].
  Transform2D shifted(Duration by) => copyWith(
    x: x.shifted(by),
    y: y.shifted(by),
    scaleX: scaleX.shifted(by),
    scaleY: scaleY.shifted(by),
    rotation: rotation.shifted(by),
    opacity: opacity.shifted(by),
  );

  /// Drops animation that falls outside a clip after a trim.
  Transform2D clampedTo(Duration limit) => copyWith(
    x: x.clampedTo(limit),
    y: y.clampedTo(limit),
    scaleX: scaleX.clampedTo(limit),
    scaleY: scaleY.clampedTo(limit),
    rotation: rotation.clampedTo(limit),
    opacity: opacity.clampedTo(limit),
  );

  Transform2D timeScaled(double factor) => copyWith(
    x: x.timeScaled(factor),
    y: y.timeScaled(factor),
    scaleX: scaleX.timeScaled(factor),
    scaleY: scaleY.timeScaled(factor),
    rotation: rotation.timeScaled(factor),
    opacity: opacity.timeScaled(factor),
  );

  Map<String, dynamic> toJson() => {
    'x': x.toJson(),
    'y': y.toJson(),
    'sx': scaleX.toJson(),
    'sy': scaleY.toJson(),
    'rot': rotation.toJson(),
    'op': opacity.toJson(),
    'ax': anchorX,
    'ay': anchorY,
    if (flipHorizontal) 'fh': true,
    if (flipVertical) 'fv': true,
    if (!crop.isNone) 'crop': crop.toJson(),
    if (blendMode != LayerBlendMode.normal) 'blend': blendMode.id,
  };

  factory Transform2D.fromJson(Map<String, dynamic>? json) {
    if (json == null) return Transform2D.identity;
    return Transform2D(
      x: AnimatableDouble.fromJson(json['x']),
      y: AnimatableDouble.fromJson(json['y']),
      scaleX: AnimatableDouble.fromJson(json['sx'], fallback: 1),
      scaleY: AnimatableDouble.fromJson(json['sy'], fallback: 1),
      rotation: AnimatableDouble.fromJson(json['rot']),
      opacity: AnimatableDouble.fromJson(json['op'], fallback: 1),
      anchorX: (json['ax'] as num?)?.toDouble() ?? 0.5,
      anchorY: (json['ay'] as num?)?.toDouble() ?? 0.5,
      flipHorizontal: json['fh'] as bool? ?? false,
      flipVertical: json['fv'] as bool? ?? false,
      crop: CropRect.fromJson((json['crop'] as Map?)?.cast<String, dynamic>()),
      blendMode: LayerBlendMode.fromId(json['blend'] as String?),
    );
  }
}

/// A [Transform2D] with every animated channel evaluated at one instant.
@immutable
class ResolvedTransform {
  const ResolvedTransform({
    required this.x,
    required this.y,
    required this.scaleX,
    required this.scaleY,
    required this.rotation,
    required this.opacity,
    required this.anchorX,
    required this.anchorY,
    required this.flipHorizontal,
    required this.flipVertical,
    required this.crop,
    required this.blendMode,
  });

  final double x;
  final double y;
  final double scaleX;
  final double scaleY;
  final double rotation;
  final double opacity;
  final double anchorX;
  final double anchorY;
  final bool flipHorizontal;
  final bool flipVertical;
  final CropRect crop;
  final LayerBlendMode blendMode;

  bool get isVisible => opacity > 0.001 && scaleX.abs() > 0.001 && scaleY.abs() > 0.001;
}
