import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/theme/app_dimens.dart';
import 'package:procut_studio/core/utils/time_utils.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/engine/timeline/timeline_view_state.dart';

Timeline _timeline() => Timeline(
  fps: 30,
  tracks: [
    Track(
      id: 'trk_v',
      type: TrackType.video,
      clips: [
        const VideoClip(
          id: 'c1',
          trackId: 'trk_v',
          start: Duration.zero,
          duration: Duration(seconds: 5),
          assetId: 'a',
        ),
        const VideoClip(
          id: 'c2',
          trackId: 'trk_v',
          start: Duration(seconds: 8),
          duration: Duration(seconds: 4),
          assetId: 'a',
        ),
      ],
    ),
  ],
);

void main() {
  group('coordinate conversion', () {
    test('time and pixels round-trip', () {
      const view = TimelineViewState(pixelsPerSecond: 60);

      expect(view.timeToPixels(const Duration(seconds: 2)), 120);
      expect(view.pixelsToTime(120), const Duration(seconds: 2));
    });

    test('scroll offsets the viewport mapping', () {
      const view = TimelineViewState(pixelsPerSecond: 60, scrollOffset: 120);

      expect(view.timeToViewportX(const Duration(seconds: 2)), 0);
      expect(view.viewportXToTime(0), const Duration(seconds: 2));
    });
  });

  group('zoom', () {
    test('keeps the focus time pinned under the focus point', () {
      const view = TimelineViewState(
        pixelsPerSecond: 60,
        viewportWidth: 600,
        scrollOffset: 0,
      );
      const focusTime = Duration(seconds: 5);
      const focusX = 300.0;

      final zoomed = view.zoomedBy(
        2.0,
        focusTime: focusTime,
        focusViewportX: focusX,
      );

      expect(zoomed.pixelsPerSecond, 120);
      expect(zoomed.timeToViewportX(focusTime), closeTo(focusX, 0.001));
    });

    test('clamps to the supported zoom range', () {
      const view = TimelineViewState(pixelsPerSecond: 60);

      expect(
        view.zoomedBy(1000, focusTime: Duration.zero, focusViewportX: 0)
            .pixelsPerSecond,
        TimelineMetrics.maxPixelsPerSecond,
      );
      expect(
        view.zoomedBy(0.0001, focusTime: Duration.zero, focusViewportX: 0)
            .pixelsPerSecond,
        TimelineMetrics.minPixelsPerSecond,
      );
    });

    test('zoomToFit puts the whole timeline on screen', () {
      const view = TimelineViewState(viewportWidth: 600);

      final fitted = view.zoomedToFit(const Duration(seconds: 12));

      expect(fitted.scrollOffset, 0);
      expect(fitted.timeToPixels(const Duration(seconds: 12)), lessThan(600));
    });
  });

  group('snapping', () {
    test('snaps to a nearby clip edge', () {
      const view = TimelineViewState(pixelsPerSecond: 60);
      // 10px threshold at 60px/s ≈ 167ms.
      final result = view.snap(
        const Duration(milliseconds: 5080),
        _timeline(),
      );

      expect(result.snapped, isTrue);
      expect(result.time, const Duration(seconds: 5));
      expect(result.target, SnapTarget.clipEdge);
    });

    test('leaves a distant position alone but frame-aligns it', () {
      const view = TimelineViewState(pixelsPerSecond: 60);

      final result = view.snap(
        const Duration(milliseconds: 6500),
        _timeline(),
      );

      expect(result.snapped, isFalse);
      // Still quantised onto the 30fps grid.
      expect(result.time, TimeUtils.snapToFrame(const Duration(milliseconds: 6500), 30));
    });

    test('snapping can be turned off', () {
      const view = TimelineViewState(pixelsPerSecond: 60, snapEnabled: false);

      final result = view.snap(
        const Duration(milliseconds: 5010),
        _timeline(),
      );

      expect(result.snapped, isFalse);
      expect(result.time, const Duration(milliseconds: 5010));
    });

    test('excludes the clip being dragged from its own snap targets', () {
      const view = TimelineViewState(pixelsPerSecond: 60);

      final result = view.snap(
        const Duration(milliseconds: 5020),
        _timeline(),
        excludeClipId: 'c1',
      );

      expect(result.snapped, isFalse);
    });

    test('snaps to the playhead when one is supplied', () {
      const view = TimelineViewState(pixelsPerSecond: 60);

      final result = view.snap(
        const Duration(milliseconds: 6980),
        _timeline(),
        playhead: const Duration(seconds: 7),
      );

      expect(result.target, SnapTarget.playhead);
      expect(result.time, const Duration(seconds: 7));
    });
  });

  group('hit testing', () {
    test('the ruler strip is identified by its y position', () {
      const view = TimelineViewState(pixelsPerSecond: 60, viewportWidth: 600);

      final hit = view.hitTest(_timeline(), 100, 5);
      expect(hit.region, ClipRegion.ruler);
    });

    test('the middle of a clip returns its body', () {
      const view = TimelineViewState(pixelsPerSecond: 60, viewportWidth: 600);
      final layout = view.trackLayouts(_timeline()).single;

      // 2.5s in at 60px/s = 150px.
      final hit = view.hitTest(_timeline(), 150, layout.top + 20);

      expect(hit.clip?.id, 'c1');
      expect(hit.region, ClipRegion.body);
    });

    test('clip edges resolve to trim handles', () {
      const view = TimelineViewState(pixelsPerSecond: 60, viewportWidth: 600);
      final layout = view.trackLayouts(_timeline()).single;

      final left = view.hitTest(_timeline(), 2, layout.top + 20);
      expect(left.region, ClipRegion.leftHandle);

      // Clip c1 ends at 5s → 300px.
      final right = view.hitTest(_timeline(), 298, layout.top + 20);
      expect(right.region, ClipRegion.rightHandle);
    });

    test('a gap on a track is reported as empty, not as a clip', () {
      const view = TimelineViewState(pixelsPerSecond: 60, viewportWidth: 600);
      final layout = view.trackLayouts(_timeline()).single;

      // 6.5s is in the gap between the two clips.
      final hit = view.hitTest(_timeline(), 390, layout.top + 20);

      expect(hit.clip, isNull);
      expect(hit.region, ClipRegion.emptyTrack);
      expect(hit.track?.id, 'trk_v');
    });
  });

  group('ruler intervals', () {
    test('picks a coarser interval as the view zooms out', () {
      const zoomedIn = TimelineViewState(pixelsPerSecond: 600);
      const zoomedOut = TimelineViewState(pixelsPerSecond: 5);

      expect(
        zoomedIn.rulerInterval().inMilliseconds,
        lessThan(zoomedOut.rulerInterval().inMilliseconds),
      );
    });

    test('labels never crowd closer than the minimum spacing', () {
      for (final pps in [4.0, 12.0, 60.0, 200.0, 1200.0]) {
        final view = TimelineViewState(pixelsPerSecond: pps);
        final spacing =
            view.rulerInterval().inMilliseconds / 1000 * pps;
        expect(
          spacing,
          greaterThanOrEqualTo(60),
          reason: 'at ${pps}px/s the ticks would overlap',
        );
      }
    });
  });

  group('track layout', () {
    test('rows are stacked below the ruler without overlapping', () {
      const view = TimelineViewState();
      final timeline = Timeline(
        tracks: [
          const Track(id: 't1', type: TrackType.video),
          const Track(id: 't2', type: TrackType.audio),
          const Track(id: 't3', type: TrackType.text),
        ],
      );

      final layouts = view.trackLayouts(timeline);

      expect(layouts, hasLength(3));
      expect(layouts.first.top, TimelineMetrics.rulerHeight);
      for (var i = 1; i < layouts.length; i++) {
        expect(layouts[i].top, greaterThanOrEqualTo(layouts[i - 1].bottom));
      }
    });

    test('the topmost visual layer is listed first', () {
      const view = TimelineViewState();
      final timeline = Timeline(
        tracks: [
          const Track(id: 'bottom', type: TrackType.video),
          const Track(id: 'top', type: TrackType.overlay),
        ],
      );

      // Track order is z-order (index 0 is the bottom layer), so the list
      // reads top-down like a layer stack.
      expect(view.trackLayouts(timeline).first.track.id, 'top');
    });
  });
}
