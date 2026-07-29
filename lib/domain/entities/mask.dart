/// A shape mask on a clip.
///
/// Every geometric field is normalised to the canvas (0..1) and animatable, so
/// a mask can follow a subject, open as a reveal, or stay put — all through the
/// same keyframe machinery the transform uses.
///
/// Preview renders it with a fragment shader; export builds an alpha channel
/// with `geq` and merges it with `alphamerge`. Both consume the same resolved
/// values, so the two paths cannot drift.
library;

import 'package:flutter/foundation.dart';

import 'keyframe.dart';

enum MaskShape {
  none('none'),
  rectangle('rectangle'),
  ellipse('ellipse'),

  /// A soft half-plane — the classic gradient reveal.
  linear('linear');

  const MaskShape(this.id);
  final String id;

  static MaskShape fromId(String? id) =>
      MaskShape.values.firstWhere((e) => e.id == id, orElse: () => MaskShape.none);

  String get label => switch (this) {
    MaskShape.none => 'None',
    MaskShape.rectangle => 'Rectangle',
    MaskShape.ellipse => 'Ellipse',
    MaskShape.linear => 'Linear',
  };
}

@immutable
class Mask {
  const Mask({
    this.shape = MaskShape.none,
    this.centerX = const AnimatableDouble.constant(0.5),
    this.centerY = const AnimatableDouble.constant(0.5),
    this.width = const AnimatableDouble.constant(0.5),
    this.height = const AnimatableDouble.constant(0.5),
    this.rotation = const AnimatableDouble.constant(0),
    this.feather = const AnimatableDouble.constant(0.05),
    this.inverted = false,
  });

  static const Mask none = Mask();

  final MaskShape shape;

  /// Centre, as a fraction of canvas width/height.
  final AnimatableDouble centerX;
  final AnimatableDouble centerY;

  /// Half-extents, as a fraction of the canvas. For [MaskShape.linear] only
  /// [height] is used, as the distance from the edge.
  final AnimatableDouble width;
  final AnimatableDouble height;

  /// Degrees, clockwise.
  final AnimatableDouble rotation;

  /// Edge softness as a fraction of the canvas. Zero is a hard edge, which
  /// aliases badly on a diagonal — the default is deliberately non-zero.
  final AnimatableDouble feather;

  /// Keeps the *outside* instead of the inside.
  final bool inverted;

  bool get isActive => shape != MaskShape.none;

  bool get isAnimated =>
      centerX.isAnimated ||
      centerY.isAnimated ||
      width.isAnimated ||
      height.isAnimated ||
      rotation.isAnimated ||
      feather.isAnimated;

  ResolvedMask resolveAt(Duration time) => ResolvedMask(
    shape: shape,
    centerX: centerX.valueAt(time),
    centerY: centerY.valueAt(time),
    width: width.valueAt(time).abs().clamp(0.001, 2.0),
    height: height.valueAt(time).abs().clamp(0.001, 2.0),
    rotation: rotation.valueAt(time),
    feather: feather.valueAt(time).clamp(0.0, 0.5),
    inverted: inverted,
  );

  Mask copyWith({
    MaskShape? shape,
    AnimatableDouble? centerX,
    AnimatableDouble? centerY,
    AnimatableDouble? width,
    AnimatableDouble? height,
    AnimatableDouble? rotation,
    AnimatableDouble? feather,
    bool? inverted,
  }) => Mask(
    shape: shape ?? this.shape,
    centerX: centerX ?? this.centerX,
    centerY: centerY ?? this.centerY,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    feather: feather ?? this.feather,
    inverted: inverted ?? this.inverted,
  );

  /// Shifts every animated channel — used when a clip is split or head-trimmed.
  Mask shifted(Duration by) => copyWith(
    centerX: centerX.shifted(by),
    centerY: centerY.shifted(by),
    width: width.shifted(by),
    height: height.shifted(by),
    rotation: rotation.shifted(by),
    feather: feather.shifted(by),
  );

  Mask clampedTo(Duration limit) => copyWith(
    centerX: centerX.clampedTo(limit),
    centerY: centerY.clampedTo(limit),
    width: width.clampedTo(limit),
    height: height.clampedTo(limit),
    rotation: rotation.clampedTo(limit),
    feather: feather.clampedTo(limit),
  );

  Map<String, dynamic> toJson() => {
    'shape': shape.id,
    'cx': centerX.toJson(),
    'cy': centerY.toJson(),
    'w': width.toJson(),
    'h': height.toJson(),
    'rot': rotation.toJson(),
    'feather': feather.toJson(),
    if (inverted) 'inverted': true,
  };

  factory Mask.fromJson(Map<String, dynamic>? json) {
    if (json == null) return Mask.none;
    return Mask(
      shape: MaskShape.fromId(json['shape'] as String?),
      centerX: AnimatableDouble.fromJson(json['cx'], fallback: 0.5),
      centerY: AnimatableDouble.fromJson(json['cy'], fallback: 0.5),
      width: AnimatableDouble.fromJson(json['w'], fallback: 0.5),
      height: AnimatableDouble.fromJson(json['h'], fallback: 0.5),
      rotation: AnimatableDouble.fromJson(json['rot']),
      feather: AnimatableDouble.fromJson(json['feather'], fallback: 0.05),
      inverted: json['inverted'] as bool? ?? false,
    );
  }
}

/// A [Mask] with every animated channel evaluated at one instant.
@immutable
class ResolvedMask {
  const ResolvedMask({
    required this.shape,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
    required this.rotation,
    required this.feather,
    required this.inverted,
  });

  final MaskShape shape;
  final double centerX;
  final double centerY;
  final double width;
  final double height;
  final double rotation;
  final double feather;
  final bool inverted;

  bool get isActive => shape != MaskShape.none;
}
