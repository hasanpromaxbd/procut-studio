/// Draws text and sticker layers onto a canvas.
///
/// This is used by **both** the live preview and the export rasteriser. That is
/// the whole point: a title composed in the editor is drawn by the same code
/// that writes the PNG the encoder consumes, so "what you see" and "what you
/// get" are the same function of the same data.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../domain/entities/clip.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/transform2d.dart';

abstract final class LayerPainter {
  /// Paints [clip] at [localTime] into [canvas], which is assumed to be in
  /// canvas pixel coordinates of [size].
  static void paintClip({
    required Canvas canvas,
    required Size size,
    required Clip clip,
    required Duration localTime,
  }) {
    final transform = clip.transform.resolveAt(localTime);
    if (!transform.isVisible) return;

    canvas.save();
    _applyTransform(canvas, size, transform);

    switch (clip) {
      case TextClip():
        _paintText(canvas, size, clip, localTime, transform.opacity);
      case StickerClip():
        _paintSticker(canvas, size, clip, transform.opacity);
      case VideoClip() || AudioClip() || ImageClip() || CompoundClip():
        break; // media layers are composited by the video pipeline
    }

    canvas.restore();
  }

  static void _applyTransform(
    Canvas canvas,
    Size size,
    ResolvedTransform transform,
  ) {
    // Translation is a fraction of canvas size so a layout survives a change
    // of export resolution.
    final dx = transform.x * size.width;
    final dy = transform.y * size.height;
    final anchor = Offset(
      size.width * transform.anchorX,
      size.height * transform.anchorY,
    );

    canvas
      ..translate(dx, dy)
      ..translate(anchor.dx, anchor.dy)
      ..rotate(transform.rotation * math.pi / 180)
      ..scale(
        transform.scaleX * (transform.flipHorizontal ? -1 : 1),
        transform.scaleY * (transform.flipVertical ? -1 : 1),
      )
      ..translate(-anchor.dx, -anchor.dy);
  }

  // ── Text ───────────────────────────────────────────────────────────

  static void _paintText(
    Canvas canvas,
    Size size,
    TextClip clip,
    Duration localTime,
    double baseOpacity,
  ) {
    final style = clip.style;
    final animation = _resolveTextAnimation(clip, localTime);
    final opacity = (baseOpacity * animation.opacity).clamp(0.0, 1.0);
    if (opacity <= 0.001) return;

    final text = _visibleText(clip, animation.reveal);
    if (text.isEmpty) return;

    final fontSize = style.fontSizePx(size.height);
    final maxWidth = size.width * 0.86;

    canvas.save();
    canvas.translate(animation.offsetX * size.width, animation.offsetY * size.height);
    if (animation.scale != 1.0) {
      final centre = Offset(size.width / 2, size.height / 2);
      canvas
        ..translate(centre.dx, centre.dy)
        ..scale(animation.scale)
        ..translate(-centre.dx, -centre.dy);
    }

    final painter = _buildTextPainter(
      text: text,
      style: style,
      fontSize: fontSize,
      opacity: opacity,
      maxWidth: maxWidth,
    );

    final origin = _textOrigin(painter, size, style);

    if (style.hasBackground) {
      final padding = style.backgroundPadding * size.height;
      final rect = Rect.fromLTWH(
        origin.dx - padding,
        origin.dy - padding * 0.6,
        painter.width + padding * 2,
        painter.height + padding * 1.2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect,
          Radius.circular(style.backgroundRadius * size.height),
        ),
        Paint()
          ..color = Color(style.backgroundColor).withValues(
            alpha: ((style.backgroundColor >> 24) & 0xFF) / 255 * opacity,
          ),
      );
    }

    // Glow first (widest), then stroke, then fill — painting order is what
    // makes an outline read as an outline rather than a smear.
    if (style.hasGlow) {
      final glow = _buildTextPainter(
        text: text,
        style: style,
        fontSize: fontSize,
        opacity: opacity,
        maxWidth: maxWidth,
        overridePaint: Paint()
          ..color = Color(style.glowColor).withValues(alpha: opacity)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            style.glowRadius * fontSize,
          ),
      );
      glow.paint(canvas, origin);
    }

    if (style.hasStroke) {
      final stroke = _buildTextPainter(
        text: text,
        style: style,
        fontSize: fontSize,
        opacity: opacity,
        maxWidth: maxWidth,
        overridePaint: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.strokeWidth * fontSize
          ..strokeJoin = StrokeJoin.round
          ..color = Color(style.strokeColor).withValues(alpha: opacity),
      );
      stroke.paint(canvas, origin);
    }

    painter.paint(canvas, origin);
    canvas.restore();
  }

  static TextPainter _buildTextPainter({
    required String text,
    required TextStyleSpec style,
    required double fontSize,
    required double opacity,
    required double maxWidth,
    Paint? overridePaint,
  }) {
    final shadows = style.shadow.isVisible && overridePaint == null
        ? [
            Shadow(
              color: Color(style.shadow.color).withValues(
                alpha: ((style.shadow.color >> 24) & 0xFF) / 255 * opacity,
              ),
              offset: Offset(
                style.shadow.offsetX * fontSize * 10,
                style.shadow.offsetY * fontSize * 10,
              ),
              blurRadius: style.shadow.blur * fontSize * 10,
            ),
          ]
        : null;

    Paint? foreground = overridePaint;
    if (foreground == null && style.hasGradient) {
      // A shader needs concrete bounds; the text box is a good enough
      // approximation and matches what the user positioned.
      final radians = style.gradientAngle * math.pi / 180;
      final extent = fontSize * 8;
      foreground = Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(math.cos(radians) * extent, math.sin(radians) * extent),
          style.gradientColors
              .map((c) => Color(c).withValues(alpha: opacity))
              .toList(),
        );
    }

    final base = _resolveFont(style, fontSize);

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: base.copyWith(
          color: foreground == null
              ? Color(style.color).withValues(alpha: opacity)
              : null,
          foreground: foreground,
          letterSpacing: style.letterSpacing * fontSize,
          height: style.lineHeight,
          shadows: shadows,
        ),
      ),
      textAlign: switch (style.alignment) {
        TextAlignment.left => TextAlign.left,
        TextAlignment.center => TextAlign.center,
        TextAlignment.right => TextAlign.right,
      },
      textDirection: TextDirection.ltr,
      maxLines: 8,
    )..layout(maxWidth: maxWidth);

    return painter;
  }

  /// Resolves a family name through Google Fonts, falling back to the platform
  /// font if the family is unknown or not cached offline.
  static TextStyle _resolveFont(TextStyleSpec style, double fontSize) {
    final weight = FontWeight.values.firstWhere(
      (w) => w.value >= style.fontWeight,
      orElse: () => FontWeight.w700,
    );
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
    );
    try {
      return GoogleFonts.getFont(
        style.fontFamily,
        fontSize: fontSize,
        fontWeight: weight,
        fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      );
    } catch (_) {
      // Unknown family, or runtime fetching disabled with nothing cached.
      return base;
    }
  }

  static Offset _textOrigin(TextPainter painter, Size size, TextStyleSpec style) {
    final dy = (size.height - painter.height) / 2;
    final dx = switch (style.alignment) {
      TextAlignment.left => size.width * 0.07,
      TextAlignment.center => (size.width - painter.width) / 2,
      TextAlignment.right => size.width * 0.93 - painter.width,
    };
    return Offset(dx, dy);
  }

  static String _visibleText(TextClip clip, double reveal) {
    final full = clip.displayText;
    if (reveal >= 1.0) return full;
    switch (clip.animationIn) {
      case TextAnimation.typewriter:
        final count = (full.length * reveal).floor().clamp(0, full.length);
        return full.substring(0, count);
      case TextAnimation.wordByWord:
        final words = full.split(' ');
        final count = (words.length * reveal).ceil().clamp(0, words.length);
        return words.take(count).join(' ');
      default:
        return full;
    }
  }

  static _TextAnimationState _resolveTextAnimation(
    TextClip clip,
    Duration localTime,
  ) {
    final inProgress = clip.animationInProgress(localTime);
    final outProgress = clip.animationOutProgress(localTime);

    var opacity = 1.0;
    var offsetX = 0.0;
    var offsetY = 0.0;
    var scale = 1.0;
    var reveal = 1.0;

    if (clip.animationIn != TextAnimation.none && inProgress < 1) {
      final t = Curves.easeOutCubic.transform(inProgress);
      switch (clip.animationIn) {
        case TextAnimation.fadeIn:
          opacity = t;
        case TextAnimation.slideUp:
          opacity = t;
          offsetY = (1 - t) * 0.08;
        case TextAnimation.slideDown:
          opacity = t;
          offsetY = -(1 - t) * 0.08;
        case TextAnimation.popIn:
          opacity = t;
          scale = 0.7 + 0.3 * Curves.easeOutBack.transform(inProgress);
        case TextAnimation.bounce:
          opacity = t;
          scale = 0.85 + 0.15 * Curves.elasticOut.transform(inProgress);
        case TextAnimation.typewriter:
        case TextAnimation.wordByWord:
          reveal = inProgress;
        case TextAnimation.wipe:
          opacity = t;
          reveal = inProgress;
        case TextAnimation.glitchIn:
          opacity = t;
          // Deterministic jitter: same frame always looks the same, which
          // matters because the exporter renders each frame independently.
          final seed = (inProgress * 37).floor();
          offsetX = (math.sin(seed * 12.9898) * 0.01) * (1 - t);
        case TextAnimation.neonFlicker:
          final flick = math.sin(inProgress * 40) * 0.5 + 0.5;
          opacity = (t * (0.55 + 0.45 * flick)).clamp(0.0, 1.0);
        case TextAnimation.none:
          break;
      }
    }

    if (clip.animationOut != TextAnimation.none && outProgress > 0) {
      final t = Curves.easeInCubic.transform(outProgress);
      switch (clip.animationOut) {
        case TextAnimation.fadeIn:
          opacity *= 1 - t;
        case TextAnimation.slideUp:
          opacity *= 1 - t;
          offsetY -= t * 0.08;
        case TextAnimation.slideDown:
          opacity *= 1 - t;
          offsetY += t * 0.08;
        case TextAnimation.popIn:
        case TextAnimation.bounce:
          opacity *= 1 - t;
          scale *= 1 - 0.2 * t;
        default:
          opacity *= 1 - t;
      }
    }

    return _TextAnimationState(
      opacity: opacity,
      offsetX: offsetX,
      offsetY: offsetY,
      scale: scale,
      reveal: reveal,
    );
  }

  // ── Stickers ───────────────────────────────────────────────────────

  static void _paintSticker(
    Canvas canvas,
    Size size,
    StickerClip clip,
    double opacity,
  ) {
    if (clip.isEmoji) {
      final fontSize = size.height * 0.18;
      final painter = TextPainter(
        text: TextSpan(
          text: clip.emoji,
          style: TextStyle(fontSize: fontSize),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
      painter.paint(
        canvas,
        Offset(
          (size.width - painter.width) / 2,
          (size.height - painter.height) / 2,
        ),
      );
      canvas.restore();
      return;
    }

    final image = StickerImageCache.get(clip.assetPath ?? clip.stickerId);
    if (image == null) return;

    final target = _fitSticker(
      Size(image.width.toDouble(), image.height.toDouble()),
      size,
    );
    final dst = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: target.width,
      height: target.height,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..color = Color.fromRGBO(255, 255, 255, opacity)
        ..filterQuality = FilterQuality.medium,
    );
  }

  static Size _fitSticker(Size source, Size canvas) {
    // Stickers default to a third of the canvas width; the user scales from
    // there with the transform handles.
    final targetWidth = canvas.width * 0.33;
    final scale = targetWidth / source.width;
    return Size(source.width * scale, source.height * scale);
  }

  const LayerPainter._();
}

class _TextAnimationState {
  const _TextAnimationState({
    required this.opacity,
    required this.offsetX,
    required this.offsetY,
    required this.scale,
    required this.reveal,
  });

  final double opacity;
  final double offsetX;
  final double offsetY;
  final double scale;
  final double reveal;
}

/// Decoded sticker images, keyed by path.
///
/// Populated before a paint pass (the painter itself must stay synchronous —
/// `CustomPainter.paint` cannot await).
abstract final class StickerImageCache {
  static final Map<String, ui.Image> _images = {};

  static ui.Image? get(String key) => _images[key];

  static void put(String key, ui.Image image) {
    _images[key]?.dispose();
    _images[key] = image;
  }

  static bool contains(String key) => _images.containsKey(key);

  static void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  const StickerImageCache._();
}
