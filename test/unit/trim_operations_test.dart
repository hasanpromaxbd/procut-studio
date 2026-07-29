/// Slip, slide, roll, razor and Ken Burns.
///
/// These are the operations where "the clip did not move" or "the programme
/// length did not change" *is* the behaviour, so the assertions are mostly
/// about what stayed the same.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/marker.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';

const _fps = 30;

VideoClip _clip({
  required String id,
  required int startSec,
  required int lengthSec,
  int sourceInSec = 10,
  double speed = 1.0,
}) => VideoClip(
  id: id,
  trackId: 'v1',
  start: Duration(seconds: startSec),
  duration: Duration(seconds: lengthSec),
  assetId: 'asset',
  sourceIn: Duration(seconds: sourceInSec),
  speed: speed,
);

/// Three clips butted together: 0–4, 4–8, 8–12.
Timeline _threeUp() => Timeline(
  fps: _fps,
  tracks: [
    Track(
      id: 'v1',
      type: TrackType.video,
      clips: [
        _clip(id: 'a', startSec: 0, lengthSec: 4),
        _clip(id: 'b', startSec: 4, lengthSec: 4),
        _clip(id: 'c', startSec: 8, lengthSec: 4),
      ],
    ),
  ],
);

VideoClip _find(Timeline t, String id) =>
    t.findClip(id)!.$2 as VideoClip;

void main() {
  group('slip', () {
    test('moves the source window and nothing else', () {
      final result = TimelineOperations.slip(
        _threeUp(),
        'b',
        const Duration(seconds: 1),
      );

      final timeline = result.valueOrNull!;
      final b = _find(timeline, 'b');
      expect(b.sourceIn, const Duration(seconds: 11));
      expect(b.start, const Duration(seconds: 4), reason: 'slip never moves the clip');
      expect(b.duration, const Duration(seconds: 4));
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('a slowed clip slips less source than the gesture', () {
      // At half speed one second of timeline is half a second of source, so
      // the window must move by half a second, not one.
      final timeline = Timeline(
        fps: _fps,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip(id: 'a', startSec: 0, lengthSec: 4, speed: 0.5)],
          ),
        ],
      );

      final result = TimelineOperations.slip(
        timeline,
        'a',
        const Duration(seconds: 1),
      );
      expect(
        _find(result.valueOrNull!, 'a').sourceIn,
        const Duration(seconds: 10, milliseconds: 500),
      );
    });

    test('clamps at the head of the source', () {
      final result = TimelineOperations.slip(
        _threeUp(),
        'b',
        const Duration(seconds: -30),
      );
      expect(_find(result.valueOrNull!, 'b').sourceIn, Duration.zero);
    });

    test('respects the asset length when told what it is', () {
      final result = TimelineOperations.slip(
        _threeUp(),
        'b',
        const Duration(seconds: 30),
        sourceLimit: const Duration(seconds: 20),
      );
      // 20s asset, 4s window → the window can start no later than 16s.
      expect(
        _find(result.valueOrNull!, 'b').sourceIn,
        const Duration(seconds: 16),
      );
    });

    test('a still has no source window to slip', () {
      final timeline = Timeline(
        fps: _fps,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: const [
              ImageClip(
                id: 'img',
                trackId: 'v1',
                start: Duration.zero,
                duration: Duration(seconds: 3),
                assetId: 'a',
              ),
            ],
          ),
        ],
      );
      expect(
        TimelineOperations.slip(timeline, 'img', const Duration(seconds: 1)).isErr,
        isTrue,
      );
    });
  });

  group('slide', () {
    test('the neighbours absorb the move and the programme length holds', () {
      final result = TimelineOperations.slide(
        _threeUp(),
        'b',
        const Duration(seconds: 1),
      );

      final timeline = result.valueOrNull!;
      expect(_find(timeline, 'a').duration, const Duration(seconds: 5));
      expect(_find(timeline, 'b').start, const Duration(seconds: 5));
      expect(_find(timeline, 'b').duration, const Duration(seconds: 4),
          reason: 'the slid clip itself is untouched');
      expect(_find(timeline, 'c').start, const Duration(seconds: 9));
      expect(_find(timeline, 'c').duration, const Duration(seconds: 3));
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('slides the other way too, with no gaps left behind', () {
      final timeline = TimelineOperations.slide(
        _threeUp(),
        'b',
        const Duration(seconds: -1),
      ).valueOrNull!;

      expect(_find(timeline, 'a').end, _find(timeline, 'b').start);
      expect(_find(timeline, 'b').end, _find(timeline, 'c').start);
      expect(_find(timeline, 'a').duration, const Duration(seconds: 3));
      expect(_find(timeline, 'c').duration, const Duration(seconds: 5));
    });

    test('refuses without a clip on both sides', () {
      // 'a' has nothing before it.
      final result = TimelineOperations.slide(
        _threeUp(),
        'a',
        const Duration(seconds: 1),
      );
      expect(result.isErr, isTrue);
    });

    test('a rejected slide changes nothing at all', () {
      final before = _threeUp();
      // 'c' has free space after it, not a clip.
      final result = TimelineOperations.slide(before, 'c', const Duration(seconds: 1));
      expect(result.isErr, isTrue);
      expect(before.clipCount, 3, reason: 'the input is never mutated');
    });
  });

  group('roll', () {
    test('one clip gains exactly what the other loses', () {
      final timeline = TimelineOperations.roll(
        _threeUp(),
        'b',
        const Duration(seconds: 1),
      ).valueOrNull!;

      expect(_find(timeline, 'b').duration, const Duration(seconds: 5));
      expect(_find(timeline, 'c').start, const Duration(seconds: 9));
      expect(_find(timeline, 'c').duration, const Duration(seconds: 3));
      expect(_find(timeline, 'a').duration, const Duration(seconds: 4),
          reason: 'a roll touches one cut, not the whole track');
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('rolling the head cut moves the other boundary', () {
      final timeline = TimelineOperations.roll(
        _threeUp(),
        'b',
        const Duration(seconds: 1),
        atStart: true,
      ).valueOrNull!;

      expect(_find(timeline, 'a').duration, const Duration(seconds: 5));
      expect(_find(timeline, 'b').start, const Duration(seconds: 5));
      expect(_find(timeline, 'b').duration, const Duration(seconds: 3));
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('the last clip has no tail cut to roll', () {
      expect(
        TimelineOperations.roll(_threeUp(), 'c', const Duration(seconds: 1)).isErr,
        isTrue,
      );
    });

    test('rolling past the far clip\'s minimum is refused whole', () {
      // 'c' is 4s; rolling 10s would leave it negative. The compound edit must
      // fail entirely rather than leaving 'b' stretched.
      final before = _threeUp();
      final result = TimelineOperations.roll(before, 'b', const Duration(seconds: 10));
      expect(result.isErr, isTrue);
    });
  });

  group('razor on beats', () {
    Timeline withBeats(List<int> secs) => _threeUp().copyWith(
      markers: [
        for (final s in secs)
          Marker(
            id: 'm$s',
            time: Duration(seconds: s),
            kind: MarkerKind.beat,
          ),
      ],
    );

    test('cuts every clip the beats cross', () {
      final timeline = TimelineOperations.razor(
        withBeats([2, 6, 10]),
        [
          const Duration(seconds: 2),
          const Duration(seconds: 6),
          const Duration(seconds: 10),
        ],
      ).valueOrNull!;

      expect(timeline.clipCount, 6, reason: 'three clips, one cut each');
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('later cuts do not invalidate earlier ones', () {
      // Two beats inside the same clip. Cutting 1s first would move what lives
      // at 3s; working backwards avoids that entirely.
      final timeline = TimelineOperations.razor(
        _threeUp(),
        [const Duration(seconds: 1), const Duration(seconds: 3)],
      ).valueOrNull!;

      final pieces = timeline.tracks.single.clips
          .where((c) => c.start < const Duration(seconds: 4))
          .toList()
        ..sort((x, y) => x.start.compareTo(y.start));

      expect(pieces.length, 3);
      expect(pieces[0].duration, const Duration(seconds: 1));
      expect(pieces[1].duration, const Duration(seconds: 2));
      expect(pieces[2].duration, const Duration(seconds: 1));
    });

    test('only cuts the clips it is told to', () {
      final timeline = TimelineOperations.razor(
        _threeUp(),
        [
          const Duration(seconds: 2),
          const Duration(seconds: 6),
        ],
        clipIds: {'a'},
      ).valueOrNull!;

      expect(timeline.clipCount, 4);
      expect(timeline.findClip('b')!.$2.duration, const Duration(seconds: 4));
    });

    test('beats that all land in gaps are an error, not a silent no-op', () {
      final timeline = Timeline(
        fps: _fps,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip(id: 'a', startSec: 0, lengthSec: 2)],
          ),
        ],
      );
      expect(
        TimelineOperations.razor(timeline, [const Duration(seconds: 9)]).isErr,
        isTrue,
      );
    });

    test('a locked clip is skipped', () {
      final timeline = Timeline(
        fps: _fps,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [
              _clip(id: 'a', startSec: 0, lengthSec: 4).copyWith(locked: true),
            ],
          ),
        ],
      );
      expect(
        TimelineOperations.razor(timeline, [const Duration(seconds: 2)]).isErr,
        isTrue,
      );
    });
  });

  group('Ken Burns', () {
    Timeline stills() => Timeline(
      fps: _fps,
      tracks: [
        Track(
          id: 'v1',
          type: TrackType.video,
          clips: const [
            ImageClip(
              id: 'img',
              trackId: 'v1',
              start: Duration.zero,
              duration: Duration(seconds: 5),
              assetId: 'photo',
            ),
          ],
        ),
      ],
    );

    test('a zoom-in ramps scale up over the whole clip', () {
      final clip = TimelineOperations.kenBurns(
        stills(),
        'img',
        zoom: 0.2,
      ).valueOrNull!.findClip('img')!.$2;

      final scale = clip.transform.scaleX;
      expect(scale.isAnimated, isTrue);
      expect(scale.valueAt(Duration.zero), closeTo(1.0, 1e-9));
      expect(scale.valueAt(const Duration(seconds: 5)), closeTo(1.2, 1e-9));
      expect(clip.duration, const Duration(seconds: 5),
          reason: 'a camera move is not a trim');
    });

    test('zoom out is the same move backwards', () {
      final scale = TimelineOperations.kenBurns(
        stills(),
        'img',
        move: KenBurnsMove.zoomOut,
        zoom: 0.2,
      ).valueOrNull!.findClip('img')!.$2.transform.scaleX;

      expect(scale.valueAt(Duration.zero), closeTo(1.2, 1e-9));
      expect(scale.valueAt(const Duration(seconds: 5)), closeTo(1.0, 1e-9));
    });

    test('a pan stays inside the headroom the zoom creates', () {
      final transform = TimelineOperations.kenBurns(
        stills(),
        'img',
        move: KenBurnsMove.panLeft,
        zoom: 0.25,
      ).valueOrNull!.findClip('img')!.$2.transform;

      // Scale is held so the pan has somewhere to travel...
      expect(transform.scaleX.valueAt(Duration.zero), closeTo(1.25, 1e-9));
      expect(transform.scaleX.valueAt(const Duration(seconds: 5)), closeTo(1.25, 1e-9));

      // ...and the travel never exceeds half the overhang, so no frame edge
      // is ever exposed.
      final limit = (0.25 / 1.25) * 0.5;
      expect(transform.x.valueAt(Duration.zero), closeTo(limit, 1e-9));
      expect(transform.x.valueAt(const Duration(seconds: 5)), closeTo(-limit, 1e-9));
      expect(transform.y.isAnimated, isFalse);
    });

    test('clearing motion keeps the value the clip starts on', () {
      final moved = TimelineOperations.kenBurns(
        stills(),
        'img',
        move: KenBurnsMove.zoomOut,
        zoom: 0.4,
      ).valueOrNull!;

      final cleared = TimelineOperations.clearMotion(moved, 'img')
          .valueOrNull!
          .findClip('img')!
          .$2
          .transform;

      expect(cleared.isAnimated, isFalse);
      expect(cleared.scaleX.valueAt(Duration.zero), closeTo(1.4, 1e-9));
    });

    test('a locked clip is left alone', () {
      final timeline = Timeline(
        fps: _fps,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: const [
              ImageClip(
                id: 'img',
                trackId: 'v1',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'photo',
                locked: true,
              ),
            ],
          ),
        ],
      );
      expect(TimelineOperations.kenBurns(timeline, 'img').isErr, isTrue);
    });
  });
}
