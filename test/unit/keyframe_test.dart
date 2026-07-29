import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';

void main() {
  group('AnimatableDouble', () {
    test('a constant property ignores time', () {
      const property = AnimatableDouble.constant(0.5);
      expect(property.valueAt(Duration.zero), 0.5);
      expect(property.valueAt(const Duration(seconds: 99)), 0.5);
      expect(property.isAnimated, isFalse);
    });

    test('interpolates linearly between two keyframes', () {
      const property = AnimatableDouble(
        0,
        keyframes: [
          Keyframe(time: Duration.zero, value: 0, easing: Easing.linear),
          Keyframe(
            time: Duration(seconds: 2),
            value: 10,
            easing: Easing.linear,
          ),
        ],
      );

      expect(property.valueAt(const Duration(seconds: 1)), closeTo(5, 0.001));
    });

    test('clamps outside the keyframe range rather than extrapolating', () {
      const property = AnimatableDouble(
        0,
        keyframes: [
          Keyframe(time: Duration(seconds: 1), value: 4),
          Keyframe(time: Duration(seconds: 2), value: 8),
        ],
      );

      expect(property.valueAt(Duration.zero), 4);
      expect(property.valueAt(const Duration(seconds: 10)), 8);
    });

    test('hold easing steps instead of ramping', () {
      const property = AnimatableDouble(
        0,
        keyframes: [
          Keyframe(time: Duration.zero, value: 1, easing: Easing.hold),
          Keyframe(time: Duration(seconds: 2), value: 9),
        ],
      );

      expect(property.valueAt(const Duration(milliseconds: 1900)), 1);
      expect(property.valueAt(const Duration(seconds: 2)), 9);
    });

    test('finds the right segment across many keyframes', () {
      // Exercises the binary search rather than a two-key shortcut.
      final keyframes = [
        for (var i = 0; i <= 100; i++)
          Keyframe(
            time: Duration(milliseconds: i * 100),
            value: i.toDouble(),
            easing: Easing.linear,
          ),
      ];
      final property = AnimatableDouble(0, keyframes: keyframes);

      expect(property.valueAt(const Duration(milliseconds: 5000)), closeTo(50, 0.001));
      expect(property.valueAt(const Duration(milliseconds: 5050)), closeTo(50.5, 0.001));
      expect(property.valueAt(const Duration(milliseconds: 9900)), closeTo(99, 0.001));
    });

    test('withKeyframe replaces rather than duplicating at the same time', () {
      var property = const AnimatableDouble(0);
      property = property.withKeyframe(
        const Keyframe(time: Duration(seconds: 1), value: 3),
      );
      property = property.withKeyframe(
        const Keyframe(time: Duration(seconds: 1), value: 7),
      );

      expect(property.keyframes, hasLength(1));
      expect(property.keyframes.single.value, 7);
    });

    test('withKeyframe keeps the list sorted', () {
      var property = const AnimatableDouble(0);
      for (final seconds in [5, 1, 3, 2]) {
        property = property.withKeyframe(
          Keyframe(time: Duration(seconds: seconds), value: seconds.toDouble()),
        );
      }

      final times = property.keyframes.map((k) => k.time).toList();
      expect(times, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 3),
        const Duration(seconds: 5),
      ]);
    });

    test('shifted moves every keyframe', () {
      const property = AnimatableDouble(
        0,
        keyframes: [Keyframe(time: Duration(seconds: 5), value: 1)],
      );

      final shifted = property.shifted(const Duration(seconds: -2));
      expect(shifted.keyframes.single.time, const Duration(seconds: 3));
    });

    test('clampedTo drops keyframes past a trim boundary', () {
      const property = AnimatableDouble(
        0,
        keyframes: [
          Keyframe(time: Duration(seconds: 1), value: 1),
          Keyframe(time: Duration(seconds: 9), value: 9),
        ],
      );

      final clamped = property.clampedTo(const Duration(seconds: 5));
      expect(clamped.keyframes, hasLength(1));
      expect(clamped.keyframes.single.time, const Duration(seconds: 1));
    });

    test('timeScaled stretches the animation with the clip', () {
      const property = AnimatableDouble(
        0,
        keyframes: [Keyframe(time: Duration(seconds: 2), value: 1)],
      );

      expect(
        property.timeScaled(0.5).keyframes.single.time,
        const Duration(seconds: 1),
      );
    });

    test('normalised removes duplicate times and sorts', () {
      const property = AnimatableDouble(
        0,
        keyframes: [
          Keyframe(time: Duration(seconds: 3), value: 3),
          Keyframe(time: Duration(seconds: 1), value: 1),
          Keyframe(time: Duration(seconds: 3), value: 99),
        ],
      );

      final normalised = property.normalised();
      expect(normalised.keyframes, hasLength(2));
      expect(normalised.keyframes.first.time, const Duration(seconds: 1));
    });
  });

  group('serialisation', () {
    test('a constant property round-trips as a bare number', () {
      const property = AnimatableDouble.constant(0.75);
      final json = property.toJson();

      expect(json, isA<double>());
      expect(AnimatableDouble.fromJson(json).valueAt(Duration.zero), 0.75);
    });

    test('an animated property round-trips with its keyframes', () {
      const property = AnimatableDouble(
        1,
        keyframes: [
          Keyframe(time: Duration.zero, value: 0, easing: Easing.easeIn),
          Keyframe(time: Duration(seconds: 1), value: 1, easing: Easing.back),
        ],
      );

      final restored = AnimatableDouble.fromJson(property.toJson());
      expect(restored.keyframes, hasLength(2));
      expect(restored.keyframes[1].easing, Easing.back);
      expect(restored.staticValue, 1);
    });

    test('a missing value falls back rather than throwing', () {
      expect(
        AnimatableDouble.fromJson(null, fallback: 1).valueAt(Duration.zero),
        1,
      );
    });
  });
}
