/// The decoration around a layer: rounded corners and a border.
///
/// Separate from [Mask] on purpose. A mask cuts a shape *out of* the picture
/// in canvas coordinates and animates; a frame follows the layer's own edges
/// and moves with it. Rounding a picture-in-picture is a property of the PiP,
/// not a shape drawn over the composition — so it lives here and is applied
/// while the layer is still at its own size, before it is placed.
library;

import 'package:flutter/foundation.dart';

@immutable
class LayerFrame {
  const LayerFrame({
    this.cornerRadius = 0,
    this.borderWidth = 0,
    this.borderColor = 0xFFFFFFFF,
  });

  static const none = LayerFrame();

  /// Corner radius as a fraction of the layer's *short* edge, 0–0.5. Using
  /// the short edge means a wide PiP and a tall one look equally rounded, and
  /// 0.5 is exactly a pill/circle.
  final double cornerRadius;

  /// Border thickness as a fraction of the short edge. Same reasoning.
  final double borderWidth;

  /// ARGB.
  final int borderColor;

  bool get isActive => cornerRadius > 0.001 || borderWidth > 0.001;
  bool get hasBorder => borderWidth > 0.001;

  /// Radius in pixels for a layer of [shortEdge] pixels, never more than half
  /// the edge — beyond that the corners overlap and the shape inverts.
  double radiusPx(double shortEdge) =>
      (cornerRadius.clamp(0.0, 0.5)) * shortEdge;

  double borderPx(double shortEdge) =>
      (borderWidth.clamp(0.0, 0.25)) * shortEdge;

  LayerFrame copyWith({
    double? cornerRadius,
    double? borderWidth,
    int? borderColor,
  }) => LayerFrame(
    cornerRadius: cornerRadius ?? this.cornerRadius,
    borderWidth: borderWidth ?? this.borderWidth,
    borderColor: borderColor ?? this.borderColor,
  );

  Map<String, dynamic> toJson() => {
    if (cornerRadius != 0) 'r': cornerRadius,
    if (borderWidth != 0) 'bw': borderWidth,
    if (borderColor != 0xFFFFFFFF) 'bc': borderColor,
  };

  static LayerFrame fromJson(Map<String, dynamic>? json) => json == null
      ? none
      : LayerFrame(
          cornerRadius: (json['r'] as num?)?.toDouble() ?? 0,
          borderWidth: (json['bw'] as num?)?.toDouble() ?? 0,
          borderColor: (json['bc'] as num?)?.toInt() ?? 0xFFFFFFFF,
        );

  @override
  bool operator ==(Object other) =>
      other is LayerFrame &&
      other.cornerRadius == cornerRadius &&
      other.borderWidth == borderWidth &&
      other.borderColor == borderColor;

  @override
  int get hashCode => Object.hash(cornerRadius, borderWidth, borderColor);
}
