/// Reshaping a keyframe's outgoing curve.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';

const _keys = [
  Keyframe(time: Duration.zero, value: 1),
  Keyframe(time: Duration(seconds: 2), value: 1.5),
  Keyframe(time: Duration(seconds: 4), value: 1),
];

Timeline _timeline({bool locked = false}) => Timeline(
  fps: 30,
  tracks: [
    Track(
      id: 'v1',
      type: TrackType.video,
      clips: [
        VideoClip(
          id: 'c',
          trackId: 'v1',
          start: Duration.zero,
          duration: const Duration(seconds: 4),
          assetId: 'a',
          locked: locked,
          transform: Transform2D.identity.copyWith(
            scaleX: const AnimatableDouble(1, keyframes: _keys),
          ),
        ),
      ],
    ),
  ],
);

void main() {
  test('replaces the keyframe at that time and leaves the rest', () {
    final result = TimelineOperations.setKeyframe(
      _timeline(),
      'c',
      TransformChannel.scaleX,
      const Keyframe(
        time: Duration(seconds: 2),
        value: 1.5,
        easing: Easing.custom,
        bezier: [0.2, 0, 0, 1],
      ),
    );

    final channel =
        result.valueOrNull!.findClip('c')!.$2.transform.scaleX;
    expect(channel.keyframes, hasLength(3));
    expect(channel.keyframes[1].easing, Easing.custom);
    expect(channel.keyframes[1].bezier, [0.2, 0, 0, 1]);
    // The neighbours are untouched.
    expect(channel.keyframes[0].easing, isNot(Easing.custom));
    expect(channel.keyframes[2].value, 1);
  });

  test('the curve actually changes how the value travels', () {
    final eased = TimelineOperations.setKeyframe(
      _timeline(),
      'c',
      TransformChannel.scaleX,
      const Keyframe(
        time: Duration.zero,
        value: 1,
        easing: Easing.custom,
        // Heavily back-loaded: barely moves for most of the segment.
        bezier: [0.9, 0, 1, 0.1],
      ),
    ).valueOrNull!.findClip('c')!.$2.transform.scaleX;

    final linear = _timeline().findClip('c')!.$2.transform.scaleX;

    final at1s = const Duration(seconds: 1);
    expect(
      eased.valueAt(at1s),
      lessThan(linear.valueAt(at1s)),
      reason: 'a back-loaded curve must lag the default at the midpoint',
    );
    // Endpoints are the keyframes themselves, whatever the curve.
    expect(eased.valueAt(Duration.zero), closeTo(1, 1e-6));
    expect(eased.valueAt(const Duration(seconds: 2)), closeTo(1.5, 1e-6));
  });

  test('a time with no keyframe is refused rather than guessed', () {
    final result = TimelineOperations.setKeyframe(
      _timeline(),
      'c',
      TransformChannel.scaleX,
      const Keyframe(time: Duration(seconds: 3), value: 2),
    );
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.message, contains('no keyframe'));
  });

  test('a locked clip is refused', () {
    expect(
      TimelineOperations.setKeyframe(
        _timeline(locked: true),
        'c',
        TransformChannel.scaleX,
        const Keyframe(time: Duration.zero, value: 1),
      ).isErr,
      isTrue,
    );
  });

  test('a channel with no keyframes has nothing to reshape', () {
    expect(
      TimelineOperations.setKeyframe(
        _timeline(),
        'c',
        TransformChannel.opacity,
        const Keyframe(time: Duration.zero, value: 1),
      ).isErr,
      isTrue,
    );
  });
}
