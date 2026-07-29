/// Zoom, scroll and snap preferences for the timeline widget.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_dimens.dart';
import '../../engine/timeline/timeline_view_state.dart';

final timelineViewControllerProvider =
    NotifierProvider<TimelineViewController, TimelineViewState>(
      TimelineViewController.new,
    );

class TimelineViewController extends Notifier<TimelineViewState> {
  @override
  TimelineViewState build() => const TimelineViewState();

  void setViewportWidth(double width) {
    if ((state.viewportWidth - width).abs() < 0.5) return;
    state = state.copyWith(viewportWidth: width);
  }

  void zoom(double factor, {required Duration focusTime, required double focusX}) {
    state = state.zoomedBy(
      factor,
      focusTime: focusTime,
      focusViewportX: focusX,
    );
  }

  void zoomIn() => _zoomAroundCentre(1.35);
  void zoomOut() => _zoomAroundCentre(1 / 1.35);

  void _zoomAroundCentre(double factor) {
    final centreX = state.viewportWidth / 2;
    state = state.zoomedBy(
      factor,
      focusTime: state.viewportXToTime(centreX),
      focusViewportX: centreX,
    );
  }

  void zoomToFit(Duration duration) => state = state.zoomedToFit(duration);

  void resetZoom() => state = state.copyWith(
    pixelsPerSecond: TimelineMetrics.basePixelsPerSecond,
  );

  void scrollTo(double offset, {Duration? contentDuration}) =>
      state = state.scrolledTo(offset, contentDuration: contentDuration);

  void scrollBy(double delta, {Duration? contentDuration}) => state = state
      .scrolledTo(state.scrollOffset + delta, contentDuration: contentDuration);

  void followPlayhead(Duration playhead, {Duration? contentDuration}) =>
      state = state.followingPlayhead(playhead, contentDuration: contentDuration);

  void toggleSnap() => state = state.copyWith(snapEnabled: !state.snapEnabled);

  void toggleRipple() =>
      state = state.copyWith(rippleEnabled: !state.rippleEnabled);
}
