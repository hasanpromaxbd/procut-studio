/// Caption restyle, merge and sync-nudge.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/subtitle.dart';
import 'package:procut_studio/domain/entities/text_style_spec.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';

TextClip _caption(
  String id,
  int startMs,
  int durMs,
  String text, {
  List<WordTiming> words = const [],
  bool isSubtitle = true,
}) => TextClip(
  id: id,
  trackId: 'txt',
  start: Duration(milliseconds: startMs),
  duration: Duration(milliseconds: durMs),
  text: text,
  isSubtitle: isSubtitle,
  wordTimings: words,
);

Timeline _timeline(List<Clip> captions, {List<Clip> extra = const []}) =>
    Timeline(
      fps: 30,
      tracks: [
        Track(id: 'txt', type: TrackType.text, clips: captions),
        if (extra.isNotEmpty)
          Track(id: 'txt2', type: TrackType.text, clips: extra),
      ],
    );

void main() {
  group('restyle', () {
    test('applies to every caption at once', () {
      final timeline = TimelineOperations.restyleCaptions(
        _timeline([
          _caption('a', 0, 1000, 'one'),
          _caption('b', 1000, 1000, 'two'),
        ]),
        const TextStyleSpec(fontSize: 0.09, allCaps: true),
      ).valueOrNull!;

      for (final id in ['a', 'b']) {
        final clip = timeline.findClip(id)!.$2 as TextClip;
        expect(clip.style.fontSize, 0.09);
        expect(clip.style.allCaps, isTrue);
      }
    });

    test('leaves hand-placed titles alone', () {
      // The whole point of the isSubtitle flag: a title sharing the track
      // must not be restyled by a caption operation.
      final timeline = TimelineOperations.restyleCaptions(
        _timeline([
          _caption('cap', 0, 1000, 'caption'),
          _caption('title', 2000, 1000, 'TITLE', isSubtitle: false),
        ]),
        const TextStyleSpec(fontSize: 0.09),
      ).valueOrNull!;

      expect((timeline.findClip('cap')!.$2 as TextClip).style.fontSize, 0.09);
      expect(
        (timeline.findClip('title')!.$2 as TextClip).style.fontSize,
        isNot(0.09),
      );
    });

    test('a timeline with no captions says so', () {
      final result = TimelineOperations.restyleCaptions(
        _timeline([_caption('t', 0, 1000, 'x', isSubtitle: false)]),
        const TextStyleSpec(),
      );
      expect(result.isErr, isTrue);
    });
  });

  group('merge', () {
    test('joins the text and spans both cues', () {
      final timeline = TimelineOperations.mergeCaption(
        _timeline([
          _caption('a', 0, 1000, 'the quick'),
          _caption('b', 1200, 800, 'brown fox'),
        ]),
        'a',
      ).valueOrNull!;

      final merged = timeline.findClip('a')!.$2 as TextClip;
      expect(merged.text, 'the quick brown fox');
      expect(merged.end, const Duration(milliseconds: 2000));
      expect(timeline.findClip('b'), isNull);
    });

    test('word timings are rebased, not left pointing at the old zero', () {
      final timeline = TimelineOperations.mergeCaption(
        _timeline([
          _caption(
            'a',
            0,
            1000,
            'the quick',
            words: const [
              WordTiming(
                start: Duration.zero,
                end: Duration(milliseconds: 400),
                text: 'the',
              ),
              WordTiming(
                start: Duration(milliseconds: 400),
                end: Duration(milliseconds: 1000),
                text: 'quick',
              ),
            ],
          ),
          _caption(
            'b',
            1200,
            800,
            'brown fox',
            words: const [
              WordTiming(
                start: Duration.zero,
                end: Duration(milliseconds: 400),
                text: 'brown',
              ),
            ],
          ),
        ]),
        'a',
      ).valueOrNull!;

      final merged = timeline.findClip('a')!.$2 as TextClip;
      expect(merged.wordTimings, hasLength(3));
      // 'brown' started at the follower's zero, which is 1200ms into the
      // merged clip — a karaoke highlight would fire a second early otherwise.
      expect(
        merged.wordTimings.last.start,
        const Duration(milliseconds: 1200),
      );
    });

    test('the last caption has nothing to merge with', () {
      final result = TimelineOperations.mergeCaption(
        _timeline([_caption('a', 0, 1000, 'only')]),
        'a',
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('no caption after'));
    });
  });

  group('nudge', () {
    test('shifts every caption by the same amount', () {
      final timeline = TimelineOperations.nudgeCaptions(
        _timeline([
          _caption('a', 1000, 500, 'one'),
          _caption('b', 3000, 500, 'two'),
        ]),
        const Duration(milliseconds: 250),
      ).valueOrNull!;

      expect(timeline.findClip('a')!.$2.start,
          const Duration(milliseconds: 1250));
      expect(timeline.findClip('b')!.$2.start,
          const Duration(milliseconds: 3250));
    });

    test('never pushes a caption before zero', () {
      // A caption at a negative time simply never renders, which reads as
      // "it deleted my captions".
      final timeline = TimelineOperations.nudgeCaptions(
        _timeline([_caption('a', 100, 500, 'early')]),
        const Duration(seconds: -5),
      ).valueOrNull!;

      expect(timeline.findClip('a')!.$2.start, Duration.zero);
    });

    test('a zero nudge is a no-op, not an error', () {
      final before = _timeline([_caption('a', 100, 500, 'x')]);
      final after = TimelineOperations.nudgeCaptions(before, Duration.zero);
      expect(after.valueOrNull!.findClip('a')!.$2.start,
          const Duration(milliseconds: 100));
    });
  });
}
