/// Pure view geometry for the timeline: zoom, scroll, hit-testing, snapping.
///
/// Deliberately free of Flutter widgets so the maths can be unit-tested and so
/// the painter, the gesture recogniser and the ruler all agree on exactly one
/// definition of "where is second 12 on screen".
library;

import 'package:flutter/foundation.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/math_utils.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/track.dart';

@immutable
class TimelineViewState {
  const TimelineViewState({
    this.pixelsPerSecond = TimelineMetrics.basePixelsPerSecond,
    this.scrollOffset = 0,
    this.viewportWidth = 0,
    this.snapEnabled = true,
    this.rippleEnabled = false,
  });

  /// Horizontal zoom.
  final double pixelsPerSecond;

  /// Pixels scrolled from the timeline origin.
  final double scrollOffset;

  final double viewportWidth;
  final bool snapEnabled;

  /// When on, deleting or moving a clip closes the gap behind it.
  final bool rippleEnabled;

  double get zoomFactor =>
      pixelsPerSecond / TimelineMetrics.basePixelsPerSecond;

  // ── Coordinate conversion ────────────────────────────────────────────

  /// Timeline time → x in content coordinates (before scroll).
  double timeToPixels(Duration time) =>
      time.inMicroseconds / 1e6 * pixelsPerSecond;

  /// Timeline time → x in viewport coordinates.
  double timeToViewportX(Duration time) => timeToPixels(time) - scrollOffset;

  Duration pixelsToTime(double pixels) => Duration(
    microseconds: (pixels / pixelsPerSecond * 1e6).round(),
  );

  Duration viewportXToTime(double x) => pixelsToTime(x + scrollOffset);

  /// Total scrollable width for a timeline of [duration], with a screen of
  /// trailing space so the last clip can be dragged past the end.
  double contentWidth(Duration duration) =>
      timeToPixels(duration) + viewportWidth * 0.5;

  /// First and last times currently on screen, padded by one clip width so
  /// partially visible clips still paint.
  (Duration from, Duration to) visibleRange() {
    final from = pixelsToTime(MathUtils.clamp(scrollOffset - 200, 0, double.infinity));
    final to = pixelsToTime(scrollOffset + viewportWidth + 200);
    return (from, to);
  }

  bool isVisible(Duration start, Duration end) {
    final (from, to) = visibleRange();
    return start < to && end > from;
  }

  // ── Zoom ─────────────────────────────────────────────────────────────

  /// Zooms while keeping [focusTime] pinned under [focusViewportX].
  /// Without the anchor, pinch-zoom drifts the content out from under the
  /// user's fingers, which feels broken even when the maths is right.
  TimelineViewState zoomedTo(
    double newPixelsPerSecond, {
    required Duration focusTime,
    required double focusViewportX,
  }) {
    final clamped = MathUtils.clamp(
      newPixelsPerSecond,
      TimelineMetrics.minPixelsPerSecond,
      TimelineMetrics.maxPixelsPerSecond,
    );
    final focusContentX = focusTime.inMicroseconds / 1e6 * clamped;
    return copyWith(
      pixelsPerSecond: clamped,
      scrollOffset: MathUtils.clamp(
        focusContentX - focusViewportX,
        0,
        double.infinity,
      ),
    );
  }

  TimelineViewState zoomedBy(
    double factor, {
    required Duration focusTime,
    required double focusViewportX,
  }) => zoomedTo(
    pixelsPerSecond * factor,
    focusTime: focusTime,
    focusViewportX: focusViewportX,
  );

  /// Zoom level that fits [duration] in the viewport.
  TimelineViewState zoomedToFit(Duration duration) {
    if (duration <= Duration.zero || viewportWidth <= 0) return this;
    final seconds = duration.inMicroseconds / 1e6;
    return copyWith(
      pixelsPerSecond: MathUtils.clamp(
        (viewportWidth * 0.92) / seconds,
        TimelineMetrics.minPixelsPerSecond,
        TimelineMetrics.maxPixelsPerSecond,
      ),
      scrollOffset: 0,
    );
  }

  TimelineViewState scrolledTo(double offset, {Duration? contentDuration}) {
    final max = contentDuration == null
        ? double.infinity
        : MathUtils.clamp(
            contentWidth(contentDuration) - viewportWidth,
            0,
            double.infinity,
          );
    return copyWith(scrollOffset: MathUtils.clamp(offset, 0, max));
  }

  /// Scrolls so the playhead stays visible, using a dead-band in the middle so
  /// the view does not shudder on every frame during playback.
  TimelineViewState followingPlayhead(
    Duration playhead, {
    Duration? contentDuration,
  }) {
    final x = timeToViewportX(playhead);
    const leadIn = 0.25;
    const leadOut = 0.75;
    if (x >= viewportWidth * leadIn && x <= viewportWidth * leadOut) {
      return this;
    }
    return scrolledTo(
      timeToPixels(playhead) - viewportWidth * leadIn,
      contentDuration: contentDuration,
    );
  }

  // ── Snapping ─────────────────────────────────────────────────────────

  /// Snaps [time] to the nearest interesting point: clip edges, the playhead,
  /// or the origin. Returns the original value when nothing is close enough.
  SnapResult snap(
    Duration time,
    Timeline timeline, {
    Duration? playhead,
    String? excludeClipId,
  }) {
    if (!snapEnabled) return SnapResult(time: time, snapped: false);

    final thresholdUs = pixelsToTime(TimelineMetrics.snapThreshold).inMicroseconds;
    var best = time;
    var bestDistance = thresholdUs + 1;
    var target = SnapTarget.none;

    void consider(Duration candidate, SnapTarget kind) {
      final distance = (candidate.inMicroseconds - time.inMicroseconds).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
        target = kind;
      }
    }

    consider(Duration.zero, SnapTarget.origin);
    if (playhead != null) consider(playhead, SnapTarget.playhead);

    // Markers are deliberate reference points, so they snap like clip edges.
    for (final marker in timeline.markers) {
      consider(marker.time, SnapTarget.marker);
    }

    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == excludeClipId) continue;
        consider(clip.start, SnapTarget.clipEdge);
        consider(clip.end, SnapTarget.clipEdge);
      }
    }

    if (target == SnapTarget.none) {
      return SnapResult(
        time: TimeUtils.snapToFrame(time, timeline.fps),
        snapped: false,
      );
    }
    return SnapResult(time: best, snapped: true, target: target);
  }

  // ── Hit testing ──────────────────────────────────────────────────────

  /// Vertical layout of the track rows, top to bottom.
  List<TrackLayout> trackLayouts(Timeline timeline) {
    final layouts = <TrackLayout>[];
    var y = TimelineMetrics.rulerHeight;
    // Drawn top-down in reverse z-order so the topmost visual layer appears
    // first in the list, matching how layer stacks read everywhere else.
    for (final track in timeline.tracks.reversed) {
      layouts.add(TrackLayout(track: track, top: y, height: track.height));
      y += track.height + TimelineMetrics.trackGap;
    }
    return layouts;
  }

  double totalHeight(Timeline timeline) {
    var height = TimelineMetrics.rulerHeight;
    for (final track in timeline.tracks) {
      height += track.height + TimelineMetrics.trackGap;
    }
    return height;
  }

  /// Finds what is under a viewport-space point.
  TimelineHit hitTest(Timeline timeline, double x, double y) {
    final layouts = trackLayouts(timeline);
    for (final layout in layouts) {
      if (y < layout.top || y > layout.top + layout.height) continue;

      final time = viewportXToTime(x);
      for (final clip in layout.track.clips) {
        final left = timeToViewportX(clip.start);
        final right = timeToViewportX(clip.end);
        if (x < left || x > right) continue;

        // Edges take priority so a thin clip can still be trimmed.
        final handle = MathUtils.clamp(
          (right - left) / 3,
          4,
          TimelineMetrics.trimHandleWidth,
        );
        if (x - left <= handle) {
          return TimelineHit(
            track: layout.track,
            clip: clip,
            region: ClipRegion.leftHandle,
            time: time,
          );
        }
        if (right - x <= handle) {
          return TimelineHit(
            track: layout.track,
            clip: clip,
            region: ClipRegion.rightHandle,
            time: time,
          );
        }
        return TimelineHit(
          track: layout.track,
          clip: clip,
          region: ClipRegion.body,
          time: time,
        );
      }
      return TimelineHit(
        track: layout.track,
        clip: null,
        region: ClipRegion.emptyTrack,
        time: time,
      );
    }
    return TimelineHit(
      track: null,
      clip: null,
      region: y < TimelineMetrics.rulerHeight
          ? ClipRegion.ruler
          : ClipRegion.background,
      time: viewportXToTime(x),
    );
  }

  /// Tick spacing that keeps ruler labels legible at the current zoom.
  /// Picks from a 1-2-5 sequence so labels land on round numbers.
  Duration rulerInterval() {
    const candidatesMs = <int>[
      100, 200, 500,
      1000, 2000, 5000,
      10000, 15000, 30000,
      60000, 120000, 300000,
      600000, 900000, 1800000, 3600000,
    ];
    const minLabelSpacingPx = 68.0;
    for (final ms in candidatesMs) {
      if (ms / 1000 * pixelsPerSecond >= minLabelSpacingPx) {
        return Duration(milliseconds: ms);
      }
    }
    return const Duration(hours: 1);
  }

  TimelineViewState copyWith({
    double? pixelsPerSecond,
    double? scrollOffset,
    double? viewportWidth,
    bool? snapEnabled,
    bool? rippleEnabled,
  }) => TimelineViewState(
    pixelsPerSecond: pixelsPerSecond ?? this.pixelsPerSecond,
    scrollOffset: scrollOffset ?? this.scrollOffset,
    viewportWidth: viewportWidth ?? this.viewportWidth,
    snapEnabled: snapEnabled ?? this.snapEnabled,
    rippleEnabled: rippleEnabled ?? this.rippleEnabled,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineViewState &&
          other.pixelsPerSecond == pixelsPerSecond &&
          other.scrollOffset == scrollOffset &&
          other.viewportWidth == viewportWidth &&
          other.snapEnabled == snapEnabled &&
          other.rippleEnabled == rippleEnabled;

  @override
  int get hashCode => Object.hash(
    pixelsPerSecond,
    scrollOffset,
    viewportWidth,
    snapEnabled,
    rippleEnabled,
  );
}

enum SnapTarget { none, origin, playhead, clipEdge, marker }

@immutable
class SnapResult {
  const SnapResult({
    required this.time,
    required this.snapped,
    this.target = SnapTarget.none,
  });

  final Duration time;
  final bool snapped;
  final SnapTarget target;
}

enum ClipRegion { body, leftHandle, rightHandle, emptyTrack, ruler, background }

@immutable
class TimelineHit {
  const TimelineHit({
    required this.track,
    required this.clip,
    required this.region,
    required this.time,
  });

  final Track? track;
  final Clip? clip;
  final ClipRegion region;
  final Duration time;

  bool get isClip => clip != null;
  bool get isHandle =>
      region == ClipRegion.leftHandle || region == ClipRegion.rightHandle;
}

@immutable
class TrackLayout {
  const TrackLayout({
    required this.track,
    required this.top,
    required this.height,
  });

  final Track track;
  final double top;
  final double height;

  double get bottom => top + height;
}
