/// Draws the whole timeline in one [CustomPainter].
///
/// A widget-per-clip tree was the obvious first design and it does not hold up:
/// a 200-clip project builds 200 `RenderObject`s, and every scroll frame walks
/// all of them. One painter draws only what intersects the viewport, so cost
/// scales with what is *visible*, not with project size.
///
/// The painter is split in two so the playhead — which moves every frame — is a
/// separate, cheap layer over a cached one. See [PlayheadPainter].
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/clip.dart';
import '../../../domain/entities/media_asset.dart';
import '../../../domain/entities/timeline.dart';
import '../../../engine/render/thumbnail_cache.dart';
import '../../../engine/timeline/timeline_view_state.dart';

class TimelinePainter extends CustomPainter {
  TimelinePainter({
    required this.timeline,
    required this.view,
    required this.selectedClipIds,
    required this.colorScheme,
    required this.thumbnails,
    required this.assetsById,
    required this.waveforms,
    this.snapGuideTime,
    this.onThumbnailNeeded,
  });

  final Timeline timeline;
  final TimelineViewState view;
  final Set<String> selectedClipIds;
  final ColorScheme colorScheme;
  final ThumbnailCache thumbnails;

  /// assetId → asset, so the painter never reaches into the project graph.
  final Map<String, MediaAsset> assetsById;

  /// assetId → normalised peaks.
  final Map<String, List<double>> waveforms;

  final Duration? snapGuideTime;

  /// Fired for thumbnails that missed the cache. The widget debounces these
  /// into async fetches and repaints when they land — the painter itself must
  /// never await.
  final void Function(String assetId, Duration time)? onThumbnailNeeded;

  static const double _labelPadding = 6;

  @override
  void paint(Canvas canvas, Size size) {
    _paintRuler(canvas, size);

    final layouts = view.trackLayouts(timeline);
    final (from, to) = view.visibleRange();

    for (final layout in layouts) {
      if (layout.bottom < 0 || layout.top > size.height) continue;
      _paintTrackBackground(canvas, size, layout);

      for (final clip in layout.track.clipsInRange(from, to)) {
        _paintClip(canvas, layout, clip);
      }
    }

    _paintMarkers(canvas, size);
    _paintSnapGuide(canvas, size);
  }

  /// Markers live in the ruler strip: a coloured flag with a label, and a thin
  /// line down the tracks so the alignment is visible where it matters.
  void _paintMarkers(Canvas canvas, Size size) {
    for (final marker in timeline.markers) {
      final x = view.timeToViewportX(marker.time);
      if (x < -40 || x > size.width + 40) continue;

      final colour = Color(marker.kind.colorValue);

      if (marker.isDense) {
        // Beat markers arrive in the hundreds — a tick, not a flag, or the
        // ruler becomes unreadable.
        canvas.drawLine(
          Offset(x, TimelineMetrics.rulerHeight - 6),
          Offset(x, TimelineMetrics.rulerHeight),
          Paint()
            ..color = colour.withValues(alpha: 0.75)
            ..strokeWidth = 1,
        );
        continue;
      }

      canvas.drawLine(
        Offset(x, TimelineMetrics.rulerHeight),
        Offset(x, size.height),
        Paint()
          ..color = colour.withValues(alpha: 0.28)
          ..strokeWidth = 1,
      );

      // Flag.
      final flag = Path()
        ..moveTo(x, TimelineMetrics.rulerHeight - 14)
        ..lineTo(x + 9, TimelineMetrics.rulerHeight - 11)
        ..lineTo(x, TimelineMetrics.rulerHeight - 8)
        ..close();
      canvas.drawPath(flag, Paint()..color = colour);

      if (marker.label.isNotEmpty) {
        _drawText(
          canvas,
          marker.label,
          Offset(x + 11, TimelineMetrics.rulerHeight - 16),
          colour,
          9,
          maxWidth: 90,
        );
      }
    }
  }

  // ── Ruler ────────────────────────────────────────────────────────────

  void _paintRuler(Canvas canvas, Size size) {
    final rulerRect = Rect.fromLTWH(0, 0, size.width, TimelineMetrics.rulerHeight);
    canvas.drawRect(
      rulerRect,
      Paint()..color = colorScheme.surfaceContainerLow,
    );

    final interval = view.rulerInterval();
    final (from, to) = view.visibleRange();

    // Start at the first tick at or before the visible range so a partially
    // scrolled label is not clipped away.
    final firstTick = (from.inMicroseconds / interval.inMicroseconds).floor();
    final lastTick = (to.inMicroseconds / interval.inMicroseconds).ceil();

    final tickPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    for (var i = firstTick; i <= lastTick; i++) {
      final time = Duration(microseconds: interval.inMicroseconds * i);
      if (time < Duration.zero) continue;
      final x = view.timeToViewportX(time);
      if (x < -60 || x > size.width + 60) continue;

      canvas.drawLine(
        Offset(x, TimelineMetrics.rulerHeight - 8),
        Offset(x, TimelineMetrics.rulerHeight),
        majorPaint,
      );

      _drawText(
        canvas,
        TimeUtils.formatShort(time),
        Offset(x + 3, 4),
        colorScheme.onSurfaceVariant,
        10,
      );

      // One subdivision between majors gives a sense of scale without
      // cluttering the strip.
      final midX = view.timeToViewportX(
        Duration(microseconds: interval.inMicroseconds * i + interval.inMicroseconds ~/ 2),
      );
      canvas.drawLine(
        Offset(midX, TimelineMetrics.rulerHeight - 4),
        Offset(midX, TimelineMetrics.rulerHeight),
        tickPaint,
      );
    }

    canvas.drawLine(
      Offset(0, TimelineMetrics.rulerHeight),
      Offset(size.width, TimelineMetrics.rulerHeight),
      Paint()..color = colorScheme.outlineVariant,
    );
  }

  // ── Tracks ───────────────────────────────────────────────────────────

  void _paintTrackBackground(Canvas canvas, Size size, TrackLayout layout) {
    final rect = Rect.fromLTWH(0, layout.top, size.width, layout.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(Radii.xs)),
      Paint()
        ..color = colorScheme.surfaceContainerLow.withValues(alpha: 0.45),
    );

    if (layout.track.locked) {
      // Diagonal hatch reads as "you cannot edit this" without needing a label
      // on every row.
      _paintHatch(canvas, rect, colorScheme.outlineVariant.withValues(alpha: 0.35));
    }
  }

  void _paintHatch(Canvas canvas, Rect rect, Color color) {
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = rect.left - rect.height; x < rect.right; x += 8) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
    canvas.restore();
  }

  // ── Clips ────────────────────────────────────────────────────────────

  void _paintClip(Canvas canvas, TrackLayout layout, Clip clip) {
    final left = view.timeToViewportX(clip.start);
    final right = view.timeToViewportX(clip.end);
    final width = right - left;
    if (width < 1) return;

    final rect = Rect.fromLTWH(left, layout.top + 2, width, layout.height - 4);
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(Radii.sm),
    );
    final isSelected = selectedClipIds.contains(clip.id);
    final accent = Color(layout.track.type.colorValue);

    canvas.save();
    canvas.clipRRect(rrect);

    // Base fill.
    canvas.drawRect(
      rect,
      Paint()
        ..color = accent.withValues(alpha: clip.enabled ? 0.22 : 0.08),
    );

    switch (clip) {
      case VideoClip():
        _paintThumbnails(canvas, rect, clip);
        // The embedded audio, as a strip along the bottom of the same clip —
        // reading the dialogue without expanding it onto an audio track.
        if (!clip.muted && !clip.isFrozen) {
          _paintWaveform(canvas, rect, clip, accent, strip: true);
        }
      case ImageClip():
        _paintThumbnails(canvas, rect, clip);
      case AudioClip():
        _paintWaveform(canvas, rect, clip, accent);
      case TextClip() || StickerClip():
        break; // label alone is enough for these compact rows
      case CompoundClip():
        _paintCompoundStripes(canvas, rect, accent);
    }

    // Gradient scrim so the label stays readable over bright footage.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomLeft,
          [
            Colors.black.withValues(alpha: 0.45),
            Colors.black.withValues(alpha: 0.05),
          ],
        ),
    );

    canvas.restore();

    // Border.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2 : 1
        ..color = isSelected
            ? AppColors.selectionRing
            : accent.withValues(alpha: 0.6),
    );

    if (width > 40) {
      _paintClipLabel(canvas, rect, clip, layout);
    }
    if (isSelected && width > 24) {
      _paintTrimHandles(canvas, rect);
    }
    if (clip.hasTransition) {
      _paintTransitionBadge(canvas, rect, clip);
    }
    _paintKeyframeMarkers(canvas, rect, clip);
  }

  void _paintThumbnails(Canvas canvas, Rect rect, MediaClip clip) {
    final asset = assetsById[clip.assetId];
    if (asset == null) return;

    final tileWidth = TimelineMetrics.thumbnailWidth;
    final count = math.min((rect.width / tileWidth).ceil(), 40);

    for (var i = 0; i < count; i++) {
      final tileLeft = rect.left + i * tileWidth;
      if (tileLeft > rect.right) break;

      // Map the tile back to a source timestamp through the clip's own
      // speed/reverse mapping, so a reversed clip shows reversed thumbnails.
      final fraction = (i * tileWidth) / math.max(rect.width, 1);
      final timelineTime = clip.start +
          Duration(
            microseconds: (clip.duration.inMicroseconds * fraction).round(),
          );
      final sourceTime = clip.sourceTimeAt(timelineTime);

      final key = ThumbnailCache.keyFor(asset, sourceTime);
      final image = thumbnails.peek(key);

      final tileRect = Rect.fromLTWH(
        tileLeft,
        rect.top,
        math.min(tileWidth, rect.right - tileLeft),
        rect.height,
      );

      if (image == null) {
        onThumbnailNeeded?.call(clip.assetId, sourceTime);
        canvas.drawRect(
          tileRect,
          Paint()..color = colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
        );
        continue;
      }

      final src = _coverRect(
        Size(image.width.toDouble(), image.height.toDouble()),
        tileRect.size,
      );
      canvas.drawImageRect(
        image,
        src,
        tileRect,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
  }

  /// Source rect that fills [target] without distorting — centre-crop.
  Rect _coverRect(Size source, Size target) {
    if (source.width <= 0 || source.height <= 0 || target.height <= 0) {
      return Rect.fromLTWH(0, 0, source.width, source.height);
    }
    final sourceAspect = source.width / source.height;
    final targetAspect = target.width / target.height;
    if (sourceAspect > targetAspect) {
      final w = source.height * targetAspect;
      return Rect.fromLTWH((source.width - w) / 2, 0, w, source.height);
    }
    final h = source.width / targetAspect;
    return Rect.fromLTWH(0, (source.height - h) / 2, source.width, h);
  }

  void _paintWaveform(
    Canvas canvas,
    Rect rect,
    MediaClip clip,
    Color accent, {
    bool strip = false,
  }) {
    final peaks = waveforms[clip.assetId];
    if (peaks == null || peaks.isEmpty) return;

    final paint = Paint()
      ..color = AppColors.waveform.withValues(alpha: strip ? 0.6 : 0.85)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    // On a video clip the waveform shares the row with thumbnails, so it
    // hugs the bottom quarter instead of the middle.
    final centreY = strip ? rect.bottom - rect.height * 0.14 : rect.center.dy;
    final halfHeight = rect.height * (strip ? 0.13 : 0.42);

    // One line per horizontal pixel; sampling the peak array by position keeps
    // this O(visible width) regardless of clip length.
    final step = math.max(1.0, rect.width / 400);
    for (var x = rect.left; x < rect.right; x += step) {
      final fraction = (x - rect.left) / math.max(rect.width, 1);
      final sourceFraction = clip.reversed ? 1 - fraction : fraction;
      final index =
          ((clip.sourceIn.inMilliseconds +
                      clip.sourceDuration.inMilliseconds * sourceFraction) /
                  1000 *
                  40)
              .round();
      if (index < 0 || index >= peaks.length) continue;

      final amplitude = peaks[index] * halfHeight;
      canvas.drawLine(
        Offset(x, centreY - amplitude),
        Offset(x, centreY + amplitude),
        paint,
      );
    }
  }

  /// Diagonal hatching marks a grouped block: visually distinct from media
  /// (thumbnails) and audio (waveform) without pretending to show content.
  void _paintCompoundStripes(Canvas canvas, Rect rect, Color accent) {
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.25)
      ..strokeWidth = 6;
    for (var x = rect.left - rect.height; x < rect.right; x += 18) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
  }

  void _paintClipLabel(Canvas canvas, Rect rect, Clip clip, TrackLayout layout) {
    final label = switch (clip) {
      TextClip() => clip.text,
      StickerClip() => clip.isEmoji ? clip.emoji! : 'Sticker',
      CompoundClip() =>
        clip.label ?? 'Group · ${clip.innerClips.length}',
      _ => clip.label ?? clip.kind.id,
    };

    final badges = <String>[
      if (clip is MediaClip && clip.isSpeedAltered)
        '${clip.speed.toStringAsFixed(clip.speed % 1 == 0 ? 0 : 1)}×',
      if (clip is MediaClip && clip.reversed) '◀',
      if (clip is VideoClip && clip.isFrozen) '❄',
      if (clip is VideoClip && clip.muted) '🔇',
      if (clip.locked) '🔒',
    ];

    _drawText(
      canvas,
      badges.isEmpty ? label : '${badges.join(' ')}  $label',
      Offset(rect.left + _labelPadding, rect.top + 4),
      Colors.white.withValues(alpha: clip.enabled ? 0.95 : 0.5),
      10.5,
      maxWidth: rect.width - _labelPadding * 2,
    );
  }

  void _paintTrimHandles(Canvas canvas, Rect rect) {
    final paint = Paint()..color = AppColors.selectionRing;
    const handleWidth = 4.0;
    final inset = rect.height * 0.22;

    for (final x in [rect.left + 2, rect.right - handleWidth - 2]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, rect.top + inset, handleWidth, rect.height - inset * 2),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  void _paintTransitionBadge(Canvas canvas, Rect rect, Clip clip) {
    final transition = clip.outTransition!;
    final width = view.timeToPixels(transition.duration);
    final badgeRect = Rect.fromLTWH(
      rect.right - width / 2,
      rect.top,
      math.max(width, 12),
      rect.height,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(4)),
      Paint()..color = AppColors.brandCyan.withValues(alpha: 0.35),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppColors.brandCyan,
    );
  }

  void _paintKeyframeMarkers(Canvas canvas, Rect rect, Clip clip) {
    if (!clip.transform.isAnimated) return;

    final times = <Duration>{
      ...clip.transform.x.keyframes.map((k) => k.time),
      ...clip.transform.y.keyframes.map((k) => k.time),
      ...clip.transform.scaleX.keyframes.map((k) => k.time),
      ...clip.transform.rotation.keyframes.map((k) => k.time),
      ...clip.transform.opacity.keyframes.map((k) => k.time),
    };

    final paint = Paint()..color = AppColors.keyframeDiamond;
    for (final time in times) {
      final x = view.timeToViewportX(clip.start + time);
      if (x < rect.left || x > rect.right) continue;
      final centre = Offset(x, rect.bottom - 6);
      // Diamond: the universal keyframe glyph.
      canvas.drawPath(
        Path()
          ..moveTo(centre.dx, centre.dy - 3.5)
          ..lineTo(centre.dx + 3.5, centre.dy)
          ..lineTo(centre.dx, centre.dy + 3.5)
          ..lineTo(centre.dx - 3.5, centre.dy)
          ..close(),
        paint,
      );
    }
  }

  void _paintSnapGuide(Canvas canvas, Size size) {
    final time = snapGuideTime;
    if (time == null) return;
    final x = view.timeToViewportX(time);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = AppColors.snapGuide
        ..strokeWidth = 1.5,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double size, {
    double? maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.timeline != timeline ||
      old.view != view ||
      !setEquals(old.selectedClipIds, selectedClipIds) ||
      old.snapGuideTime != snapGuideTime ||
      old.waveforms.length != waveforms.length ||
      old.colorScheme != colorScheme;
}

/// The playhead, painted on its own layer.
///
/// Separating it means playback repaints ~200 bytes of geometry instead of
/// re-rasterising every clip, thumbnail and waveform on screen. This is the
/// single biggest reason the timeline holds 60fps during playback.
class PlayheadPainter extends CustomPainter {
  const PlayheadPainter({
    required this.position,
    required this.view,
    required this.isPlaying,
  });

  final Duration position;
  final TimelineViewState view;
  final bool isPlaying;

  @override
  void paint(Canvas canvas, Size size) {
    final x = view.timeToViewportX(position);
    if (x < -4 || x > size.width + 4) return;

    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = AppColors.playhead
        ..strokeWidth = TimelineMetrics.playheadWidth,
    );

    // Grab handle at the top, inside the ruler strip.
    final head = Path()
      ..moveTo(x - 7, 0)
      ..lineTo(x + 7, 0)
      ..lineTo(x + 7, 12)
      ..lineTo(x, 19)
      ..lineTo(x - 7, 12)
      ..close();
    canvas.drawPath(head, Paint()..color = AppColors.playhead);
  }

  @override
  bool shouldRepaint(PlayheadPainter old) =>
      old.position != position ||
      old.view != view ||
      old.isPlaying != isPlaying;
}
