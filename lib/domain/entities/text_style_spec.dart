/// Typography for text layers.
///
/// Sizes are expressed as a fraction of canvas height rather than in points, so
/// a title composed on a 1080p project stays visually identical when exported
/// at 4K. Converting to pixels is the renderer's job.
library;

import 'package:flutter/foundation.dart';

enum TextAlignment {
  left('left'),
  center('center'),
  right('right');

  const TextAlignment(this.id);
  final String id;

  static TextAlignment fromId(String? id) => TextAlignment.values.firstWhere(
    (e) => e.id == id,
    orElse: () => TextAlignment.center,
  );
}

/// Entry/exit animation for a title.
enum TextAnimation {
  none('none'),
  fadeIn('fade_in'),
  slideUp('slide_up'),
  slideDown('slide_down'),
  popIn('pop_in'),
  typewriter('typewriter'),
  wordByWord('word_by_word'),
  bounce('bounce'),
  glitchIn('glitch_in'),
  wipe('wipe'),
  neonFlicker('neon_flicker');

  const TextAnimation(this.id);
  final String id;

  static TextAnimation fromId(String? id) => TextAnimation.values.firstWhere(
    (e) => e.id == id,
    orElse: () => TextAnimation.none,
  );

  /// Animations that reveal glyph-by-glyph need per-character layout, which is
  /// materially more expensive — the renderer uses this to pick a path.
  bool get isPerGlyph =>
      this == TextAnimation.typewriter ||
      this == TextAnimation.wordByWord ||
      this == TextAnimation.wipe;
}

@immutable
class TextShadowSpec {
  const TextShadowSpec({
    this.color = 0xCC000000,
    this.offsetX = 0.002,
    this.offsetY = 0.003,
    this.blur = 0.006,
  });

  static const TextShadowSpec none = TextShadowSpec(color: 0x00000000, blur: 0);

  /// ARGB.
  final int color;

  /// Fractions of canvas height, same convention as font size.
  final double offsetX;
  final double offsetY;
  final double blur;

  bool get isVisible => ((color >> 24) & 0xFF) > 0 && blur >= 0;

  Map<String, dynamic> toJson() => {
    'c': color,
    'ox': offsetX,
    'oy': offsetY,
    'b': blur,
  };

  factory TextShadowSpec.fromJson(Map<String, dynamic>? json) => json == null
      ? TextShadowSpec.none
      : TextShadowSpec(
          color: (json['c'] as num?)?.toInt() ?? 0xCC000000,
          offsetX: (json['ox'] as num?)?.toDouble() ?? 0,
          offsetY: (json['oy'] as num?)?.toDouble() ?? 0,
          blur: (json['b'] as num?)?.toDouble() ?? 0,
        );
}

@immutable
class TextStyleSpec {
  const TextStyleSpec({
    this.fontFamily = 'Inter',
    this.fontWeight = 700,
    this.italic = false,
    this.fontSize = 0.06,
    this.color = 0xFFFFFFFF,
    this.gradientColors = const [],
    this.gradientAngle = 90,
    this.strokeWidth = 0,
    this.strokeColor = 0xFF000000,
    this.glowRadius = 0,
    this.glowColor = 0xFF7C5CFF,
    this.shadow = TextShadowSpec.none,
    this.backgroundColor = 0x00000000,
    this.backgroundPadding = 0.012,
    this.backgroundRadius = 0.008,
    this.alignment = TextAlignment.center,
    this.letterSpacing = 0,
    this.lineHeight = 1.2,
    this.allCaps = false,
  });

  /// A Google Fonts family name; resolved at render time.
  final String fontFamily;
  final int fontWeight;
  final bool italic;

  /// Fraction of canvas height.
  final double fontSize;

  /// ARGB fill used when [gradientColors] is empty.
  final int color;

  /// Two or more ARGB stops paint the glyphs with a gradient shader.
  final List<int> gradientColors;

  /// Degrees, 0 = left→right.
  final double gradientAngle;

  /// Outline width as a fraction of font size.
  final double strokeWidth;
  final int strokeColor;

  /// Outer glow radius as a fraction of font size.
  final double glowRadius;
  final int glowColor;

  final TextShadowSpec shadow;

  /// Plate behind the text; fully transparent by default.
  final int backgroundColor;
  final double backgroundPadding;
  final double backgroundRadius;

  final TextAlignment alignment;
  final double letterSpacing;
  final double lineHeight;
  final bool allCaps;

  bool get hasGradient => gradientColors.length >= 2;
  bool get hasStroke => strokeWidth > 0.0001;
  bool get hasGlow => glowRadius > 0.0001;
  bool get hasBackground => ((backgroundColor >> 24) & 0xFF) > 0;

  /// Font size in device pixels for a canvas [canvasHeight] px tall.
  double fontSizePx(double canvasHeight) => fontSize * canvasHeight;

  TextStyleSpec copyWith({
    String? fontFamily,
    int? fontWeight,
    bool? italic,
    double? fontSize,
    int? color,
    List<int>? gradientColors,
    double? gradientAngle,
    double? strokeWidth,
    int? strokeColor,
    double? glowRadius,
    int? glowColor,
    TextShadowSpec? shadow,
    int? backgroundColor,
    double? backgroundPadding,
    double? backgroundRadius,
    TextAlignment? alignment,
    double? letterSpacing,
    double? lineHeight,
    bool? allCaps,
  }) => TextStyleSpec(
    fontFamily: fontFamily ?? this.fontFamily,
    fontWeight: fontWeight ?? this.fontWeight,
    italic: italic ?? this.italic,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    gradientColors: gradientColors ?? this.gradientColors,
    gradientAngle: gradientAngle ?? this.gradientAngle,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    strokeColor: strokeColor ?? this.strokeColor,
    glowRadius: glowRadius ?? this.glowRadius,
    glowColor: glowColor ?? this.glowColor,
    shadow: shadow ?? this.shadow,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    backgroundPadding: backgroundPadding ?? this.backgroundPadding,
    backgroundRadius: backgroundRadius ?? this.backgroundRadius,
    alignment: alignment ?? this.alignment,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    lineHeight: lineHeight ?? this.lineHeight,
    allCaps: allCaps ?? this.allCaps,
  );

  Map<String, dynamic> toJson() => {
    'font': fontFamily,
    'weight': fontWeight,
    if (italic) 'italic': true,
    'size': fontSize,
    'color': color,
    if (gradientColors.isNotEmpty) 'grad': gradientColors,
    if (gradientColors.isNotEmpty) 'gradAngle': gradientAngle,
    if (strokeWidth > 0) 'strokeW': strokeWidth,
    if (strokeWidth > 0) 'strokeC': strokeColor,
    if (glowRadius > 0) 'glowR': glowRadius,
    if (glowRadius > 0) 'glowC': glowColor,
    if (shadow.isVisible) 'shadow': shadow.toJson(),
    if (hasBackground) 'bg': backgroundColor,
    if (hasBackground) 'bgPad': backgroundPadding,
    if (hasBackground) 'bgRadius': backgroundRadius,
    'align': alignment.id,
    if (letterSpacing != 0) 'tracking': letterSpacing,
    'leading': lineHeight,
    if (allCaps) 'caps': true,
  };

  factory TextStyleSpec.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TextStyleSpec();
    return TextStyleSpec(
      fontFamily: json['font'] as String? ?? 'Inter',
      fontWeight: (json['weight'] as num?)?.toInt() ?? 700,
      italic: json['italic'] as bool? ?? false,
      fontSize: (json['size'] as num?)?.toDouble() ?? 0.06,
      color: (json['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
      gradientColors:
          ((json['grad'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
      gradientAngle: (json['gradAngle'] as num?)?.toDouble() ?? 90,
      strokeWidth: (json['strokeW'] as num?)?.toDouble() ?? 0,
      strokeColor: (json['strokeC'] as num?)?.toInt() ?? 0xFF000000,
      glowRadius: (json['glowR'] as num?)?.toDouble() ?? 0,
      glowColor: (json['glowC'] as num?)?.toInt() ?? 0xFF7C5CFF,
      shadow: TextShadowSpec.fromJson(
        (json['shadow'] as Map?)?.cast<String, dynamic>(),
      ),
      backgroundColor: (json['bg'] as num?)?.toInt() ?? 0x00000000,
      backgroundPadding: (json['bgPad'] as num?)?.toDouble() ?? 0.012,
      backgroundRadius: (json['bgRadius'] as num?)?.toDouble() ?? 0.008,
      alignment: TextAlignment.fromId(json['align'] as String?),
      letterSpacing: (json['tracking'] as num?)?.toDouble() ?? 0,
      lineHeight: (json['leading'] as num?)?.toDouble() ?? 1.2,
      allCaps: json['caps'] as bool? ?? false,
    );
  }
}
