/// The editing rules are pure functions, so they are tested directly —
/// no widgets, no device, no FFmpeg.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/constants/app_constants.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/domain/entities/transition.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';

// ── Fixtures ─────────────────────────────────────────────────────────

const _trackId = 'trk_video';

VideoClip _video({
  String id = 'clip_a',
  Duration start = Duration.zero,
  Duration duration = const Duration(seconds: 10),
  Duration sourceIn = Duration.zero,
  double speed = 1.0,
  bool reversed = false,
  Transform2D? transform,
}) => VideoClip(
  id: id,
  trackId: _trackId,
  start: start,
  duration: duration,
  assetId: 'ast_1',
  sourceIn: sourceIn,
  speed: speed,
  reversed: reversed,
  transform: transform ?? Transform2D.identity,
);

Timeline _timelineWith(List<Clip> clips, {int fps = 30}) => Timeline(
  fps: fps,
  tracks: [
    Track(id: _trackId, type: TrackType.video, clips: clips),
  ],
);

void main() {
  group('split', () {
    test('divides a clip into two adjacent halves', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      expect(result.isOk, isTrue);
      final track = result.unwrap().tracks.single;
      expect(track.clips, hasLength(2));

      final left = track.clips[0];
      final right = track.clips[1];
      expect(left.start, Duration.zero);
      expect(left.duration, const Duration(seconds: 4));
      expect(right.start, const Duration(seconds: 4));
      expect(right.duration, const Duration(seconds: 6));
      // No gap and no overlap: the halves must exactly tile the original.
      expect(left.end, right.start);
      expect(right.end, const Duration(seconds: 10));
    });

    test('advances the source in-point of the second half', () {
      final timeline = _timelineWith([
        _video(sourceIn: const Duration(seconds: 2)),
      ]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      final right = result.unwrap().tracks.single.clips[1] as VideoClip;
      // 2s original offset + 4s consumed by the first half.
      expect(right.sourceIn, const Duration(seconds: 6));
    });

    test('accounts for speed when computing the source in-point', () {
      final timeline = _timelineWith([
        // 2x speed: 5s of timeline consumes 10s of source.
        _video(duration: const Duration(seconds: 5), speed: 2.0),
      ]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 2),
      );

      final right = result.unwrap().tracks.single.clips[1] as VideoClip;
      // 2s of timeline at 2x consumed 4s of source.
      expect(right.sourceIn, const Duration(seconds: 4));
    });

    test('swaps the source ranges for a reversed clip', () {
      final timeline = _timelineWith([
        _video(sourceIn: const Duration(seconds: 5), reversed: true),
      ]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      final clips = result.unwrap().tracks.single.clips;
      final left = clips[0] as VideoClip;
      final right = clips[1] as VideoClip;

      // Source window is 5s..15s, played backwards. The first four seconds of
      // timeline show the *last* four seconds of that window.
      expect(left.sourceIn, const Duration(seconds: 11));
      expect(right.sourceIn, const Duration(seconds: 5));
    });

    test('shifts the second half keyframes back to a zero-based clock', () {
      final transform = Transform2D.identity.copyWith(
        opacity: const AnimatableDouble(1).withKeyframe(
          const Keyframe(time: Duration(seconds: 6), value: 0.5),
        ),
      );
      final timeline = _timelineWith([_video(transform: transform)]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      final right = result.unwrap().tracks.single.clips[1];
      expect(
        right.transform.opacity.keyframes.single.time,
        const Duration(seconds: 2),
        reason: 'a keyframe 6s into the original is 2s into the second half',
      );
    });

    test('rejects a split that would leave a sub-frame fragment', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(milliseconds: 5),
      );

      expect(result.isErr, isTrue);
    });

    test('rejects a split outside the clip', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 30),
      );

      expect(result.isErr, isTrue);
    });

    test('refuses to split a locked clip', () {
      final timeline = _timelineWith([
        _video().copyWith(locked: true),
      ]);

      final result = TimelineOperations.split(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      expect(result.isErr, isTrue);
    });
  });

  group('trim', () {
    test('head trim moves start and advances the source in-point', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.trimStart(
        timeline,
        'clip_a',
        const Duration(seconds: 3),
      );

      final clip = result.unwrap().tracks.single.clips.single as VideoClip;
      expect(clip.start, const Duration(seconds: 3));
      expect(clip.duration, const Duration(seconds: 7));
      expect(clip.sourceIn, const Duration(seconds: 3));
      expect(clip.end, const Duration(seconds: 10), reason: 'tail is unmoved');
    });

    test('head trim will not cross the previous clip', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.trimStart(
        timeline,
        'clip_b',
        const Duration(seconds: 2),
      );

      expect(result.isErr, isTrue);
    });

    test('tail trim is capped by the remaining source material', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.trimEnd(
        timeline,
        'clip_a',
        const Duration(seconds: 30),
        sourceLimit: const Duration(seconds: 12),
      );

      final clip = result.unwrap().tracks.single.clips.single;
      expect(clip.duration, const Duration(seconds: 12));
    });

    test('tail trim never goes below one frame', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.trimEnd(
        timeline,
        'clip_a',
        Duration.zero,
      );

      final clip = result.unwrap().tracks.single.clips.single;
      expect(clip.duration >= AppConstants.minClipDuration, isTrue);
    });
  });

  group('move', () {
    test('repositions a clip on its own track', () {
      final timeline = _timelineWith([
        _video(duration: const Duration(seconds: 3)),
      ]);

      final result = TimelineOperations.move(
        timeline,
        'clip_a',
        const Duration(seconds: 8),
      );

      expect(result.unwrap().tracks.single.clips.single.start,
          const Duration(seconds: 8));
    });

    test('rejects a move that would overlap another clip', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.move(
        timeline,
        'clip_b',
        const Duration(seconds: 2),
      );

      expect(result.isErr, isTrue);
    });

    test('clamps a negative position to zero', () {
      final timeline = _timelineWith([
        _video(start: const Duration(seconds: 5)),
      ]);

      final result = TimelineOperations.move(
        timeline,
        'clip_a',
        const Duration(seconds: -3),
      );

      expect(result.unwrap().tracks.single.clips.single.start, Duration.zero);
    });

    test('refuses a clip kind the target track does not accept', () {
      final timeline = Timeline(
        tracks: [
          Track(id: _trackId, type: TrackType.video, clips: [_video()]),
          const Track(id: 'trk_audio', type: TrackType.audio),
        ],
      );

      final result = TimelineOperations.move(
        timeline,
        'clip_a',
        Duration.zero,
        targetTrackId: 'trk_audio',
      );

      expect(result.isErr, isTrue);
    });
  });

  group('delete', () {
    test('leaves a gap by default', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.delete(timeline, 'clip_a');
      final clips = result.unwrap().tracks.single.clips;

      expect(clips, hasLength(1));
      expect(clips.single.start, const Duration(seconds: 5));
    });

    test('ripple closes the gap behind it', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.delete(
        timeline,
        'clip_a',
        ripple: true,
      );

      expect(result.unwrap().tracks.single.clips.single.start, Duration.zero);
    });
  });

  group('speed', () {
    test('halves the timeline length at 2x, preserving source material', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.setSpeed(timeline, 'clip_a', 2.0);

      final clip = result.unwrap().tracks.single.clips.single as VideoClip;
      expect(clip.duration, const Duration(seconds: 5));
      expect(clip.sourceDuration, const Duration(seconds: 10));
    });

    test('doubles the timeline length at 0.5x', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.setSpeed(timeline, 'clip_a', 0.5);

      expect(result.unwrap().tracks.single.clips.single.duration,
          const Duration(seconds: 20));
    });

    test('ripples following clips so the cut pattern survives', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 10)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 10),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.setSpeed(timeline, 'clip_a', 2.0);
      final clips = result.unwrap().tracks.single.clips;

      expect(clips[0].duration, const Duration(seconds: 5));
      expect(clips[1].start, const Duration(seconds: 5));
    });

    test('clamps to the supported range', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.setSpeed(timeline, 'clip_a', 999);
      final clip = result.unwrap().tracks.single.clips.single as VideoClip;

      expect(clip.speed, AppConstants.maxClipSpeed);
    });

    test('rejects a speed change on a clip kind that has none', () {
      final timeline = Timeline(
        tracks: [
          Track(
            id: 'trk_text',
            type: TrackType.text,
            clips: [
              const TextClip(
                id: 'clip_t',
                trackId: 'trk_text',
                start: Duration.zero,
                duration: Duration(seconds: 3),
                text: 'hello',
              ),
            ],
          ),
        ],
      );

      final result = TimelineOperations.setSpeed(timeline, 'clip_t', 2);
      expect(result.isErr, isTrue);
    });
  });

  group('freeze frame', () {
    test('produces three clips and extends the timeline by the hold', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.freezeFrame(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
        holdDuration: const Duration(seconds: 2),
      );

      final clips = result.unwrap().tracks.single.clips;
      expect(clips, hasLength(3));

      final frozen = clips[1] as VideoClip;
      expect(frozen.isFrozen, isTrue);
      expect(frozen.duration, const Duration(seconds: 2));
      expect(frozen.muted, isTrue, reason: 'a still frame has no live audio');

      // 10s original + 2s hold.
      expect(result.unwrap().duration, const Duration(seconds: 12));
    });

    test('the frozen clip reports the same source time throughout', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.freezeFrame(
        timeline,
        'clip_a',
        const Duration(seconds: 4),
      );

      final frozen = result.unwrap().tracks.single.clips[1] as VideoClip;
      expect(
        frozen.sourceTimeAt(frozen.start),
        frozen.sourceTimeAt(frozen.end - const Duration(milliseconds: 1)),
      );
    });
  });

  group('transitions', () {
    test('adding one pulls the following clip back by the overlap', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.setTransition(
        timeline,
        'clip_a',
        const Transition(
          id: 'trn_1',
          type: TransitionType.fade,
          duration: Duration(milliseconds: 600),
        ),
      );

      final clips = result.unwrap().tracks.single.clips;
      expect(clips[1].start, const Duration(milliseconds: 4400));
      expect(result.unwrap().duration, const Duration(milliseconds: 9400));
    });

    test('removing one restores the original positions', () {
      var timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      timeline = TimelineOperations.setTransition(
        timeline,
        'clip_a',
        const Transition(
          id: 'trn_1',
          type: TransitionType.fade,
          duration: Duration(milliseconds: 600),
        ),
      ).unwrap();

      timeline = TimelineOperations.removeTransition(timeline, 'clip_a').unwrap();

      expect(timeline.tracks.single.clips[1].start, const Duration(seconds: 5));
      expect(timeline.duration, const Duration(seconds: 10));
    });

    test('rejects a transition on the last clip of a track', () {
      final timeline = _timelineWith([_video()]);

      final result = TimelineOperations.setTransition(
        timeline,
        'clip_a',
        const Transition(id: 'trn_1', type: TransitionType.fade),
      );

      expect(result.isErr, isTrue);
    });

    test('clamps the duration to half the shorter neighbour', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 1)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 1),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.setTransition(
        timeline,
        'clip_a',
        const Transition(
          id: 'trn_1',
          type: TransitionType.fade,
          duration: Duration(seconds: 4),
        ),
      );

      final transition = result.unwrap().tracks.single.clips[0].outTransition!;
      expect(transition.duration, const Duration(milliseconds: 500));
    });
  });

  group('duplicate', () {
    test('inserts a copy after the original and shifts the rest', () {
      final timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      final result = TimelineOperations.duplicate(timeline, 'clip_a');
      final clips = result.unwrap().tracks.single.clips;

      expect(clips, hasLength(3));
      expect(clips[1].start, const Duration(seconds: 5));
      expect(clips[2].start, const Duration(seconds: 10));
      expect(clips[1].id, isNot('clip_a'), reason: 'the copy gets a fresh id');
    });
  });

  group('invariants', () {
    test('every operation keeps clips sorted by start time', () {
      var timeline = _timelineWith([
        _video(id: 'clip_a', duration: const Duration(seconds: 5)),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 5),
        ),
      ]);

      timeline = TimelineOperations.split(
        timeline,
        'clip_b',
        const Duration(seconds: 7),
      ).unwrap();
      timeline = TimelineOperations.duplicate(timeline, 'clip_a').unwrap();

      final starts = timeline.tracks.single.clips.map((c) => c.start).toList();
      final sorted = List<Duration>.of(starts)..sort();
      expect(starts, sorted);
    });

    test('closeGaps compacts a track to the origin', () {
      final timeline = _timelineWith([
        _video(
          id: 'clip_a',
          start: const Duration(seconds: 3),
          duration: const Duration(seconds: 2),
        ),
        _video(
          id: 'clip_b',
          start: const Duration(seconds: 9),
          duration: const Duration(seconds: 2),
        ),
      ]);

      final result = TimelineOperations.closeGaps(timeline, _trackId);
      final clips = result.unwrap().tracks.single.clips;

      expect(clips[0].start, Duration.zero);
      expect(clips[1].start, const Duration(seconds: 2));
    });
  });
}
