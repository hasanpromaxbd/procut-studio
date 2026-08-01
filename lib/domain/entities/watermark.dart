/// A branding image composited over every exported frame.
///
/// Deliberately an *export* setting, not a clip: a watermark belongs to the
/// delivery, not to the edit. Putting it on the timeline would mean
/// remembering to remove it before a client master and re-adding it for the
/// social cut — which is exactly the mistake this avoids.
library;

import 'package:flutter/foundation.dart';

enum WatermarkCorner {
  topLeft('Top left'),
  topRight('Top right'),
  bottomLeft('Bottom left'),
  bottomRight('Bottom right');

  const WatermarkCorner(this.label);
  final String label;
}

@immutable
class Watermark {
  const Watermark({
    this.imagePath = '',
    this.corner = WatermarkCorner.bottomRight,
    this.scale = 0.16,
    this.opacity = 0.75,
    this.margin = 0.035,
  });

  static const none = Watermark();

  final String imagePath;
  final WatermarkCorner corner;

  /// Width as a fraction of the frame's width.
  final double scale;

  final double opacity;

  /// Inset from the frame edges, as a fraction of the frame's width.
  final double margin;

  bool get isActive => imagePath.trim().isNotEmpty && opacity > 0.01;

  /// The `overlay` x/y expressions for this placement.
  ///
  /// Expressions rather than numbers because the overlay filter knows the
  /// watermark's scaled size (`w`/`h`) and the frame's (`W`/`H`), and letting
  /// it do that arithmetic keeps the placement right whatever the export
  /// resolution turns out to be.
  (String x, String y) overlayPosition(int frameWidth) {
    final inset = (margin * frameWidth).round();
    return switch (corner) {
      WatermarkCorner.topLeft => ('$inset', '$inset'),
      WatermarkCorner.topRight => ('W-w-$inset', '$inset'),
      WatermarkCorner.bottomLeft => ('$inset', 'H-h-$inset'),
      WatermarkCorner.bottomRight => ('W-w-$inset', 'H-h-$inset'),
    };
  }

  Watermark copyWith({
    String? imagePath,
    WatermarkCorner? corner,
    double? scale,
    double? opacity,
    double? margin,
    bool clearImage = false,
  }) => Watermark(
    imagePath: clearImage ? '' : (imagePath ?? this.imagePath),
    corner: corner ?? this.corner,
    scale: scale ?? this.scale,
    opacity: opacity ?? this.opacity,
    margin: margin ?? this.margin,
  );

  Map<String, dynamic> toJson() => {
    'path': imagePath,
    'corner': corner.name,
    'scale': scale,
    'opacity': opacity,
    'margin': margin,
  };

  static Watermark fromJson(Map<String, dynamic>? json) => json == null
      ? none
      : Watermark(
          imagePath: json['path'] as String? ?? '',
          corner: WatermarkCorner.values.firstWhere(
            (c) => c.name == json['corner'],
            orElse: () => WatermarkCorner.bottomRight,
          ),
          scale: (json['scale'] as num?)?.toDouble() ?? 0.16,
          opacity: (json['opacity'] as num?)?.toDouble() ?? 0.75,
          margin: (json['margin'] as num?)?.toDouble() ?? 0.035,
        );

  @override
  bool operator ==(Object other) =>
      other is Watermark &&
      other.imagePath == imagePath &&
      other.corner == corner &&
      other.scale == scale &&
      other.opacity == opacity &&
      other.margin == margin;

  @override
  int get hashCode =>
      Object.hash(imagePath, corner, scale, opacity, margin);
}
