/// PiP dressing and split-screen arrangements.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/layer_frame.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/effects/frame_compiler.dart';

VideoClip _clip(String id) => VideoClip(
  id: id,
  trackId: 'v1',
  start: Duration(seconds: int.parse(id.substring(1)) * 5),
  duration: const Duration(seconds: 5),
  assetId: 'a',
);

Timeline _timeline(int clips) => Timeline(
  fps: 30,
  width: 1080,
  height: 1920,
  tracks: [
    Track(
      id: 'v1',
      type: TrackType.video,
      clips: [for (var i = 0; i < clips; i++) _clip('c$i')],
    ),
  ],
);

void main() {
  group('LayerFrame', () {
    test('is inert until something is set', () {
      expect(LayerFrame.none.isActive, isFalse);
      expect(FrameCompiler.build(LayerFrame.none, 400, 300), isEmpty);
    });

    test('the radius is measured on the short edge', () {
      const frame = LayerFrame(cornerRadius: 0.25);
      // A wide layer and a tall one round by the same number of pixels, so
      // they look equally rounded rather than one looking squashed.
      expect(frame.radiusPx(400), 100);
      expect(frame.radiusPx(200), 50);
    });

    test('the radius cannot exceed half the edge', () {
      // Beyond half the corners overlap and the shape inverts.
      const frame = LayerFrame(cornerRadius: 5);
      expect(frame.radiusPx(200), 100);
    });

    test('rounding alone writes alpha and leaves colour untouched', () {
      final filters = FrameCompiler.build(
        const LayerFrame(cornerRadius: 0.2),
        400,
        200,
      );
      final geq = filters.last.build();
      expect(geq, startsWith('geq='));
      expect(geq, contains('a='));
      expect(geq, contains("lum='p(X\\,Y)'"),
          reason: 'no border means the picture passes through unchanged');
    });

    test('a border mixes its colour into every plane', () {
      final geq = FrameCompiler.build(
        const LayerFrame(
          cornerRadius: 0.1,
          borderWidth: 0.05,
          borderColor: 0xFFFFFFFF,
        ),
        400,
        200,
      ).last.build();

      // White is luma 255, chroma neutral 128 — a border that only changed
      // luma would tint.
      expect(geq, contains('255'));
      expect(geq, contains('128'));
    });

    test('survives the JSON round trip', () {
      const frame = LayerFrame(
        cornerRadius: 0.3,
        borderWidth: 0.02,
        borderColor: 0xFFE0324B,
      );
      expect(LayerFrame.fromJson(frame.toJson()), frame);
    });

    test('an inert frame serialises to nothing', () {
      expect(LayerFrame.none.toJson(), isEmpty);
    });
  });

  group('applyLayout', () {
    test('side by side puts the first clip on the left', () {
      final result = TimelineOperations.applyLayout(
        _timeline(2),
        ['c0', 'c1'],
        SplitLayout.sideBySide,
      );

      final timeline = result.valueOrNull!;
      final a = timeline.findClip('c0')!.$2.transform;
      final b = timeline.findClip('c1')!.$2.transform;
      expect(a.x.staticValue, -0.25);
      expect(b.x.staticValue, 0.25);
      expect(a.scaleX.staticValue, 0.5);
    });

    test('picture in picture leaves the first clip full frame', () {
      final timeline = TimelineOperations.applyLayout(
        _timeline(2),
        ['c0', 'c1'],
        SplitLayout.pictureInPicture,
      ).valueOrNull!;

      expect(timeline.findClip('c0')!.$2.transform.scaleX.staticValue, 1);
      expect(
        timeline.findClip('c1')!.$2.transform.scaleX.staticValue,
        lessThan(0.5),
      );
    });

    test('clips beyond the layout keep their own position', () {
      // Three clips into a two-cell layout: the third is left alone rather
      // than stacked on top of the second.
      final timeline = TimelineOperations.applyLayout(
        _timeline(3),
        ['c0', 'c1', 'c2'],
        SplitLayout.sideBySide,
      ).valueOrNull!;

      expect(timeline.findClip('c2')!.$2.transform.isIdentity, isTrue);
    });

    test('an empty selection is refused', () {
      expect(
        TimelineOperations.applyLayout(
          _timeline(1),
          const [],
          SplitLayout.grid,
        ).isErr,
        isTrue,
      );
    });

    test('a locked clip is skipped, not silently moved', () {
      final timeline = Timeline(
        fps: 30,
        width: 1080,
        height: 1920,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('c0').copyWith(locked: true), _clip('c1')],
          ),
        ],
      );

      final result = TimelineOperations.applyLayout(
        timeline,
        ['c0', 'c1'],
        SplitLayout.sideBySide,
      ).valueOrNull!;

      expect(result.findClip('c0')!.$2.transform.isIdentity, isTrue);
      expect(result.findClip('c1')!.$2.transform.x.staticValue, 0.25);
    });

    test('every layout has as many cells as it claims', () {
      for (final layout in SplitLayout.values) {
        expect(layout.cells, hasLength(layout.capacity));
        expect(layout.cells.every((c) => c.scale > 0), isTrue);
      }
    });
  });
}
