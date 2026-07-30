/// Silence detection and the jump-cut edit built on it.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/audio/silence_detector.dart';

const _sps = 40; // AppConstants.waveformSamplesPerSecond

/// Builds a peak envelope from (seconds, level) segments.
Float32List _envelope(List<(double, double)> segments) {
  final samples = <double>[];
  for (final (seconds, level) in segments) {
    samples.addAll(List.filled((seconds * _sps).round(), level));
  }
  return Float32List.fromList(samples);
}

void main() {
  group('detection', () {
    test('finds the gap between two spoken stretches', () {
      final peaks = _envelope([
        (3, 0.6), // speech
        (2, 0.01), // silence
        (3, 0.55), // speech
      ]);

      final spans = SilenceDetector.detect(peaks);
      expect(spans, hasLength(1));
      // Padding pulls the cut inside the silence on both sides.
      expect(spans.single.start, greaterThan(const Duration(seconds: 3)));
      expect(spans.single.end, lessThan(const Duration(seconds: 5)));
      expect(spans.single.length, greaterThan(const Duration(seconds: 1)));
    });

    test('the threshold tracks the recording, not an absolute level', () {
      // A very quiet recording: speech at 0.05, gaps at 0.002. An absolute
      // threshold near "normal" levels would call all of it silence.
      final peaks = _envelope([
        (3, 0.05),
        (2, 0.002),
        (3, 0.05),
      ]);

      final spans = SilenceDetector.detect(peaks);
      expect(spans, hasLength(1), reason: 'only the true gap is silence');
    });

    test('breath-length pauses are kept', () {
      final peaks = _envelope([
        (2, 0.6),
        (0.3, 0.01), // a breath, not a silence
        (2, 0.6),
      ]);
      expect(SilenceDetector.detect(peaks), isEmpty);
    });

    test('a loud one-off does not redefine silence', () {
      // Mostly quiet speech with one clap. The 90th percentile ignores the
      // clap; the speech stays speech.
      final samples = List<double>.filled(8 * _sps, 0.2);
      samples[100] = 1.0;
      for (var i = 4 * _sps; i < 5 * _sps; i++) {
        samples[i] = 0.005;
      }
      final spans = SilenceDetector.detect(Float32List.fromList(samples));
      expect(spans, hasLength(1));
    });

    test('an entirely silent clip is one whole span', () {
      final spans = SilenceDetector.detect(_envelope([(5, 0.0)]));
      expect(spans, hasLength(1));
      expect(spans.single.start, Duration.zero);
      expect(spans.single.end, const Duration(seconds: 5));
    });

    test('edge silences keep their outer edge unpadded', () {
      final peaks = _envelope([
        (2, 0.01), // leading silence
        (4, 0.6),
        (2, 0.01), // trailing silence
      ]);
      final spans = SilenceDetector.detect(peaks);
      expect(spans, hasLength(2));
      expect(spans.first.start, Duration.zero,
          reason: 'nothing before the clip to protect');
      expect(spans.last.end, const Duration(seconds: 8));
    });
  });

  group('removeSilences', () {
    Timeline talkingHead({Duration sourceIn = Duration.zero}) => Timeline(
      fps: 30,
      tracks: [
        Track(
          id: 'v1',
          type: TrackType.video,
          clips: [
            VideoClip(
              id: 'talk',
              trackId: 'v1',
              start: Duration.zero,
              duration: const Duration(seconds: 20),
              assetId: 'a',
              sourceIn: sourceIn,
            ),
          ],
        ),
      ],
    );

    test('an interior silence becomes a jump cut with no gap', () {
      final result = TimelineOperations.removeSilences(
        talkingHead(),
        'talk',
        [(start: const Duration(seconds: 8), end: const Duration(seconds: 11))],
      );

      final timeline = result.valueOrNull!;
      final clips = timeline.tracks.single.clips;
      expect(clips, hasLength(2));
      expect(clips[0].duration, const Duration(seconds: 8));
      expect(clips[1].start, clips[0].end, reason: 'ripple closed the gap');
      expect(timeline.duration, const Duration(seconds: 17));

      // The second piece must resume *after* the silence in source time.
      final second = clips[1] as VideoClip;
      expect(second.sourceIn, const Duration(seconds: 11));
    });

    test('several silences come out in one operation', () {
      final result = TimelineOperations.removeSilences(
        talkingHead(),
        'talk',
        [
          (start: const Duration(seconds: 3), end: const Duration(seconds: 5)),
          (start: const Duration(seconds: 10), end: const Duration(seconds: 14)),
        ],
      );

      final timeline = result.valueOrNull!;
      expect(timeline.tracks.single.clips, hasLength(3));
      expect(timeline.duration, const Duration(seconds: 14));
    });

    test('a silence spanning the head trims rather than splits', () {
      final result = TimelineOperations.removeSilences(
        talkingHead(),
        'talk',
        [(start: Duration.zero, end: const Duration(seconds: 4))],
      );

      final timeline = result.valueOrNull!;
      final clip = timeline.tracks.single.clips.single as VideoClip;
      expect(clip.start, Duration.zero, reason: 'the gap is closed');
      expect(clip.duration, const Duration(seconds: 16));
      expect(clip.sourceIn, const Duration(seconds: 4));
    });

    test('a silence at the tail is a plain trim', () {
      final result = TimelineOperations.removeSilences(
        talkingHead(),
        'talk',
        [(start: const Duration(seconds: 15), end: const Duration(seconds: 20))],
      );
      final clip = result.valueOrNull!.tracks.single.clips.single;
      expect(clip.duration, const Duration(seconds: 15));
    });

    test('spans are given in source time, not timeline time', () {
      // The clip starts 5s into its source. A silence at source 8–11s sits at
      // timeline 3–6s.
      final result = TimelineOperations.removeSilences(
        talkingHead(sourceIn: const Duration(seconds: 5)),
        'talk',
        [(start: const Duration(seconds: 8), end: const Duration(seconds: 11))],
      );

      final clips = result.valueOrNull!.tracks.single.clips;
      expect(clips[0].duration, const Duration(seconds: 3));
    });

    test('a reversed clip is refused with a reason, not mis-cut', () {
      final timeline = Timeline(
        fps: 30,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: const [
              VideoClip(
                id: 'talk',
                trackId: 'v1',
                start: Duration.zero,
                duration: Duration(seconds: 20),
                assetId: 'a',
                reversed: true,
              ),
            ],
          ),
        ],
      );
      final result = TimelineOperations.removeSilences(
        timeline,
        'talk',
        [(start: const Duration(seconds: 5), end: const Duration(seconds: 8))],
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('reverse'));
    });

    test('spans outside the clip window are simply skipped', () {
      final result = TimelineOperations.removeSilences(
        talkingHead(),
        'talk',
        [
          (start: const Duration(seconds: 40), end: const Duration(seconds: 45)),
          (start: const Duration(seconds: 8), end: const Duration(seconds: 10)),
        ],
      );
      expect(result.valueOrNull!.duration, const Duration(seconds: 18));
    });
  });
}
