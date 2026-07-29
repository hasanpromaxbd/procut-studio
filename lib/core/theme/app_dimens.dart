/// Layout constants. Centralised so the timeline maths and the widget tree
/// never disagree about how tall a track is.
library;

import 'package:flutter/widgets.dart';

abstract final class Spacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  const Spacing._();
}

abstract final class Radii {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius sheetRadius = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
  static const BorderRadius clipRadius = BorderRadius.all(Radius.circular(sm));

  const Radii._();
}

/// Timeline geometry — read by both [TimelinePainter] and the gesture layer.
abstract final class TimelineMetrics {
  /// Height of one video/overlay track row.
  static const double videoTrackHeight = 64;

  /// Audio rows are shorter; the waveform reads fine at this height.
  static const double audioTrackHeight = 48;

  /// Text/sticker rows are compact chips.
  static const double compactTrackHeight = 34;

  /// Vertical gap between track rows.
  static const double trackGap = 6;

  /// The time ruler strip above the tracks.
  static const double rulerHeight = 28;

  /// Width of the playhead line.
  static const double playheadWidth = 2;

  /// Hit-test slop around a clip edge for the trim handles, in logical px.
  /// 20dp ≈ a comfortable thumb target while still allowing a 3-frame clip to
  /// be grabbed in the middle.
  static const double trimHandleWidth = 20;

  /// Default horizontal zoom: logical pixels per second at 1.0x.
  static const double basePixelsPerSecond = 60;

  static const double minPixelsPerSecond = 4;
  static const double maxPixelsPerSecond = 1200;

  /// Distance (px) within which the playhead/clip edge snaps to a target.
  static const double snapThreshold = 10;

  /// Thumbnail tile width along the timeline.
  static const double thumbnailWidth = 48;

  const TimelineMetrics._();
}

abstract final class Breakpoints {
  /// Below this we lay out as a phone: timeline docked to the bottom.
  static const double compact = 600;

  /// At/above this we use the tablet layout: inspector rail beside the preview.
  static const double medium = 840;
  static const double expanded = 1200;

  static bool isCompact(double width) => width < compact;
  static bool isTablet(double width) => width >= compact;
  static bool isExpanded(double width) => width >= expanded;

  const Breakpoints._();
}

abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 360);
  static const Duration deliberate = Duration(milliseconds: 520);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve standard = Curves.easeInOutCubic;

  /// Slight overshoot for elements that "pop" — selection rings, chips.
  static const Curve emphasized = Curves.easeOutBack;

  const Motion._();
}
