/// Audio sync, pre-render planning and the angle switch.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/audio/audio_sync.dart';
import 'package:procut_studio/engine/effects/effect_catalog.dart';
import 'package:procut_studio/engine/render/prerender_planner.dart';

const _sps = 40; // AppConstants.waveformSamplesPerSecond

/// A repeatable "performance": a few loud bursts in quiet, so two recordings
/// of it correlate the way real audio does.
Float32List _take({required int seconds, int seed = 7}) {
  final random = math.Random(seed);
  final samples = Float32List(seconds * _sps);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = 0.02 + random.nextDouble() * 0.02;
  }
  for (final at in [1.0, 2.4, 3.1, 5.5, 7.2]) {
    final index = (at * _sps).round();
    for (var i = 0; i < 8 && index + i < samples.length; i++) {
      samples[index + i] = 0.9 - i * 0.08;
    }
  }
  return samples;
}

/// The same take, heard [offsetSeconds] later and at a different level.
Float32List _delayed(Float32List take, double offsetSeconds, double gain) {
  final shift = (offsetSeconds * _sps).round();
  final out = Float32List(take.length + shift.abs());
  for (var i = 0; i < out.length; i++) {
    final source = i - shift;
    out[i] = (source >= 0 && source < take.length ? take[source] : 0.03) * gain;
  }
  return out;
}

void main() {
  group('audio sync', () {
    test('finds the offset between two recordings of one take', () {
      final a = _take(seconds: 10);
      final b = _delayed(a, 1.5, 0.6);

      final result = AudioSync.align(a, b);
      expect(
        result.offset.inMilliseconds,
        closeTo(-1500, 60),
        reason: 'b heard the take 1.5s later, so it started 1.5s earlier',
      );
      expect(result.isTrustworthy, isTrue);
    });

    test('level differences do not affect the match', () {
      final a = _take(seconds: 10);
      final quiet = _delayed(a, 0.8, 0.15);
      final loud = _delayed(a, 0.8, 1.6);

      final one = AudioSync.align(a, quiet);
      final two = AudioSync.align(a, loud);
      expect(one.offset, two.offset);
    });

    test('two different takes do not claim a confident match', () {
      final a = _take(seconds: 10, seed: 1);
      final b = _take(seconds: 10, seed: 99);
      // Different seeds move the bursts, so this is genuinely other material.
      final result = AudioSync.align(
        a,
        Float32List.fromList([
          for (var i = 0; i < b.length; i++) 0.02 + (i % 17) * 0.001,
        ]),
      );
      expect(result.isTrustworthy, isFalse);
    });

    test('an empty envelope is not a match', () {
      final result = AudioSync.align(_take(seconds: 5), Float32List(0));
      expect(result.confidence, 0);
      expect(result.isTrustworthy, isFalse);
    });

    test('a sliver of overlap is refused however well it correlates', () {
      final a = _take(seconds: 10);
      final result = AudioSync.align(a, Float32List.sublistView(a, 0, 10));
      expect(result.isTrustworthy, isFalse, reason: 'overlap too short');
    });
  });

  group('angle switching', () {
    Timeline base() => Timeline(
      fps: 30,
      tracks: [
        Track(
          id: 'v1',
          type: TrackType.video,
          clips: const [
            VideoClip(
              id: 'wide',
              trackId: 'v1',
              start: Duration.zero,
              duration: Duration(seconds: 20),
              assetId: 'camA',
            ),
          ],
        ),
      ],
    );

    test('cuts and points the second half at the new angle', () {
      final timeline = TimelineOperations.switchAngle(
        base(),
        'wide',
        const Duration(seconds: 8),
        angleAssetId: 'camB',
        angleSourceIn: const Duration(seconds: 12),
        angleLabel: 'Close',
      ).valueOrNull!;

      final clips = timeline.tracks.single.clips
        ..sort((a, b) => a.start.compareTo(b.start));
      expect(clips, hasLength(2));
      expect((clips.first as VideoClip).assetId, 'camA');

      final second = clips.last as VideoClip;
      expect(second.assetId, 'camB');
      expect(second.sourceIn, const Duration(seconds: 12));
      expect(second.start, const Duration(seconds: 8));
      expect(second.label, 'Close');
    });

    test('the programme length is unchanged by a switch', () {
      final timeline = TimelineOperations.switchAngle(
        base(),
        'wide',
        const Duration(seconds: 8),
        angleAssetId: 'camB',
        angleSourceIn: Duration.zero,
      ).valueOrNull!;
      expect(timeline.duration, const Duration(seconds: 20));
    });

    test('switching to the angle already showing is refused', () {
      final result = TimelineOperations.switchAngle(
        base(),
        'wide',
        const Duration(seconds: 8),
        angleAssetId: 'camA',
        angleSourceIn: Duration.zero,
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('already on screen'));
    });

    test('the result is ordinary clips a later edit can cut again', () {
      var timeline = TimelineOperations.switchAngle(
        base(),
        'wide',
        const Duration(seconds: 8),
        angleAssetId: 'camB',
        angleSourceIn: Duration.zero,
      ).valueOrNull!;

      final second = timeline.tracks.single.clips
          .firstWhere((c) => c.start == const Duration(seconds: 8));
      timeline = TimelineOperations.switchAngle(
        timeline,
        second.id,
        const Duration(seconds: 14),
        angleAssetId: 'camC',
        angleSourceIn: Duration.zero,
      ).valueOrNull!;

      expect(timeline.tracks.single.clips, hasLength(3));
      expect(timeline.duration, const Duration(seconds: 20));
    });
  });

  group('pre-render planning', () {
    VideoClip clip(String id, String trackId, int start, int length) =>
        VideoClip(
          id: id,
          trackId: trackId,
          start: Duration(seconds: start),
          duration: Duration(seconds: length),
          assetId: 'a',
        );

    test('a plain cut needs no pre-rendering', () {
      final timeline = Timeline(
        fps: 30,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [clip('a', 'v1', 0, 10), clip('b', 'v1', 10, 10)],
          ),
        ],
      );
      expect(PrerenderPlanner.plan(timeline), isEmpty);
    });

    test('stacking past the decoder budget is flagged', () {
      final timeline = Timeline(
        fps: 30,
        tracks: [
          for (var i = 0; i < 6; i++)
            Track(
              id: 't$i',
              type: i == 0 ? TrackType.video : TrackType.overlay,
              clips: [clip('c$i', 't$i', 0, 10)],
            ),
        ],
      );

      final spans = PrerenderPlanner.plan(timeline);
      expect(spans, isNotEmpty);
      expect(spans.first.reason, contains('video layers'));
      expect(spans.first.cost, greaterThan(PrerenderPlanner.heavyThreshold));
    });

    test('only the heavy stretch is flagged, not the whole timeline', () {
      final heavy = [
        for (var i = 0; i < 6; i++)
          Track(
            id: 't$i',
            type: i == 0 ? TrackType.video : TrackType.overlay,
            // The pile-up only exists in the middle ten seconds.
            clips: [clip('c$i', 't$i', 10, 10)],
          ),
      ];
      final timeline = Timeline(
        fps: 30,
        tracks: [
          Track(
            id: 'base',
            type: TrackType.video,
            clips: [clip('base', 'base', 0, 40)],
          ),
          ...heavy,
        ],
      );

      final spans = PrerenderPlanner.plan(timeline);
      expect(spans, hasLength(1));
      expect(spans.single.start.inSeconds, closeTo(10, 1));
      expect(spans.single.end.inSeconds, closeTo(20, 1));
    });

    test('a deep effect stack counts even on one layer', () {
      final effects = [
        for (final type in [
          EffectType.blur,
          EffectType.glow,
          EffectType.filmGrain,
          EffectType.vignette,
          EffectType.rgbSplit,
        ])
          EffectCatalog.specFor(type)!.instantiate('fx_${type.name}'),
      ];
      final timeline = Timeline(
        fps: 30,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [clip('a', 'v1', 0, 10).copyWith(effects: effects)],
          ),
        ],
      );

      final spans = PrerenderPlanner.plan(timeline);
      expect(spans, isNotEmpty);
      expect(spans.first.reason, contains('effect'));
    });

    test('a hidden track costs nothing', () {
      final timeline = Timeline(
        fps: 30,
        tracks: [
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [clip('a', 'v1', 0, 10)],
          ),
          for (var i = 0; i < 6; i++)
            Track(
              id: 'h$i',
              type: TrackType.overlay,
              hidden: true,
              clips: [clip('h$i', 'h$i', 0, 10)],
            ),
        ],
      );
      expect(PrerenderPlanner.plan(timeline), isEmpty);
    });

    test('total duration sums the spans', () {
      const spans = [
        PrerenderSpan(
          start: Duration.zero,
          end: Duration(seconds: 4),
          cost: 2,
          reason: 'x',
        ),
        PrerenderSpan(
          start: Duration(seconds: 10),
          end: Duration(seconds: 16),
          cost: 2,
          reason: 'x',
        ),
      ];
      expect(PrerenderPlanner.totalDuration(spans), const Duration(seconds: 10));
    });
  });
}
