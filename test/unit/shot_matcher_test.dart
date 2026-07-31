/// Shot matching: the judgement, without a video file in sight.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/engine/effects/shot_matcher.dart';

FrameStats _stats({
  double y = 128,
  double low = 16,
  double high = 235,
  double u = 128,
  double v = 128,
  double sat = 60,
}) => FrameStats(
  yAverage: y,
  yLow: low,
  yHigh: high,
  uAverage: u,
  vAverage: v,
  saturation: sat,
);

void main() {
  group('parsing', () {
    test('reads a signalstats map', () {
      final stats = FrameStats.fromSignalStats(const {
        'YAVG': 96.5,
        'YLOW': 20,
        'YHIGH': 200,
        'UAVG': 130,
        'VAVG': 124,
        'SATAVG': 44,
      });
      expect(stats!.yAverage, 96.5);
      expect(stats.range, 180);
    });

    test('a reading with no luma is not a frame', () {
      expect(FrameStats.fromSignalStats(const {'SATAVG': 40}), isNull);
    });
  });

  group('matching', () {
    test('identical shots need no correction', () {
      final match = ShotMatcher.match(shot: _stats(), reference: _stats());
      expect(match.isNegligible, isTrue);
      expect(match.describe(), contains('already match'));
    });

    test('a dark shot is brightened toward the reference', () {
      final match = ShotMatcher.match(
        shot: _stats(y: 80),
        reference: _stats(y: 140),
      );
      expect(match.brightness, greaterThan(0));
      expect(match.describe(), contains('brighter'));
    });

    test('a bright shot is darkened', () {
      final match = ShotMatcher.match(
        shot: _stats(y: 190),
        reference: _stats(y: 120),
      );
      expect(match.brightness, lessThan(0));
    });

    test('a flat shot gains contrast', () {
      final match = ShotMatcher.match(
        shot: _stats(low: 90, high: 150),
        reference: _stats(low: 16, high: 235),
      );
      expect(match.contrast, greaterThan(1.2));
    });

    test('a blue shot is warmed toward a warm reference', () {
      // High U is blue; high V is red.
      final match = ShotMatcher.match(
        shot: _stats(u: 150, v: 110),
        reference: _stats(u: 110, v: 150),
      );
      expect(match.temperature, greaterThan(0));
      expect(match.describe(), contains('warmer'));
    });

    test('a warm shot is cooled', () {
      final match = ShotMatcher.match(
        shot: _stats(u: 108, v: 152),
        reference: _stats(u: 140, v: 116),
      );
      expect(match.temperature, lessThan(0));
    });

    test('extremes are clamped rather than destroying the shot', () {
      // Night exterior against a lit interior: an unclamped correction here
      // would blow the frame out entirely.
      final match = ShotMatcher.match(
        shot: _stats(y: 8, low: 0, high: 20, sat: 2),
        reference: _stats(y: 220, low: 40, high: 255, sat: 120),
      );
      expect(match.brightness, lessThanOrEqualTo(0.35));
      expect(match.contrast, lessThanOrEqualTo(1.6));
      expect(match.saturation, lessThanOrEqualTo(1.7));
    });

    test('a near-monochrome shot is not multiplied into neon', () {
      final match = ShotMatcher.match(
        shot: _stats(sat: 1),
        reference: _stats(sat: 90),
      );
      expect(match.saturation, 1.0);
    });

    test('the correction reaches the colour effect by name', () {
      final params = ShotMatcher.match(
        shot: _stats(y: 90),
        reference: _stats(y: 130),
      ).toParams();
      expect(
        params.keys,
        containsAll(['brightness', 'contrast', 'saturation', 'temperature']),
      );
    });
  });

  group('distance', () {
    test('identical shots are zero apart', () {
      expect(ShotMatcher.distance(_stats(), _stats()), 0);
    });

    test('a big exposure gap reads as far apart', () {
      expect(
        ShotMatcher.distance(_stats(y: 20), _stats(y: 220)),
        greaterThan(0.5),
      );
    });

    test('a strong cast difference counts even at matched exposure', () {
      expect(
        ShotMatcher.distance(_stats(v: 128), _stats(v: 220)),
        greaterThan(0.5),
      );
    });

    test('never exceeds one', () {
      expect(
        ShotMatcher.distance(
          _stats(y: 0, u: 0, v: 0),
          _stats(y: 255, u: 255, v: 255),
        ),
        lessThanOrEqualTo(1),
      );
    });
  });
}
