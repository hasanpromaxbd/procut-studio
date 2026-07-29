/// Keyframe animation primitives.
///
/// Design note: every animatable property is a **scalar**. A 2-D position is
/// two tracks (`x`, `y`), not one track of points. That is how NLEs model it,
/// and it is what lets a user ease X independently of Y — which is the whole
/// reason to have keyframes rather than a tween.
library;

import 'dart:math' as math;
import 'package:flutter/animation.dart' show Curve, Cubic, Curves;
import 'package:flutter/foundation.dart';

import '../../core/utils/math_utils.dart';

/// Interpolation used on the segment that *starts* at a given keyframe.
enum Easing {
  /// Constant until the next keyframe — for step/stutter looks.
  hold('hold'),
  linear('linear'),
  easeIn('easeIn'),
  easeOut('easeOut'),
  easeInOut('easeInOut'),

  /// Slight overshoot past the target before settling.
  back('back'),

  /// User-defined cubic bézier via [Keyframe.bezier].
  custom('custom');

  const Easing(this.id);
  final String id;

  static Easing fromId(String? id) =>
      Easing.values.firstWhere((e) => e.id == id, orElse: () => Easing.linear);

  Curve get curve => switch (this) {
    Easing.hold => Curves.linear, // handled specially before curve lookup
    Easing.linear => Curves.linear,
    Easing.easeIn => Curves.easeInCubic,
    Easing.easeOut => Curves.easeOutCubic,
    Easing.easeInOut => Curves.easeInOutCubic,
    Easing.back => Curves.easeOutBack,
    Easing.custom => Curves.linear,
  };
}

@immutable
class Keyframe {
  const Keyframe({
    required this.time,
    required this.value,
    this.easing = Easing.easeInOut,
    this.bezier,
  });

  /// Offset from the start of the owning clip (not the timeline), so trimming
  /// or moving a clip never invalidates its keyframes.
  final Duration time;
  final double value;
  final Easing easing;

  /// Control points for [Easing.custom], as `[x1, y1, x2, y2]`.
  final List<double>? bezier;

  Curve get curve {
    if (easing == Easing.custom && bezier != null && bezier!.length == 4) {
      return Cubic(bezier![0], bezier![1], bezier![2], bezier![3]);
    }
    return easing.curve;
  }

  Keyframe copyWith({
    Duration? time,
    double? value,
    Easing? easing,
    List<double>? bezier,
  }) => Keyframe(
    time: time ?? this.time,
    value: value ?? this.value,
    easing: easing ?? this.easing,
    bezier: bezier ?? this.bezier,
  );

  Map<String, dynamic> toJson() => {
    't': time.inMicroseconds,
    'v': value,
    'e': easing.id,
    if (bezier != null) 'b': bezier,
  };

  factory Keyframe.fromJson(Map<String, dynamic> json) => Keyframe(
    time: Duration(microseconds: (json['t'] as num?)?.toInt() ?? 0),
    value: (json['v'] as num?)?.toDouble() ?? 0,
    easing: Easing.fromId(json['e'] as String?),
    bezier: (json['b'] as List?)?.map((e) => (e as num).toDouble()).toList(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Keyframe &&
          other.time == time &&
          other.value == value &&
          other.easing == easing;

  @override
  int get hashCode => Object.hash(time, value, easing);

  @override
  String toString() => 'Keyframe(${time.inMilliseconds}ms → $value)';
}

/// A scalar property that is either constant or driven by keyframes.
///
/// Kept as one type (rather than `double | List<Keyframe>`) so the renderer can
/// call [valueAt] unconditionally and never branch on animation state.
@immutable
class AnimatableDouble {
  const AnimatableDouble(this.staticValue, {this.keyframes = const []});

  const AnimatableDouble.constant(double value)
    : staticValue = value,
      keyframes = const [];

  final double staticValue;

  /// Sorted by time. [normalised] guarantees the ordering.
  final List<Keyframe> keyframes;

  bool get isAnimated => keyframes.length >= 2;

  /// Evaluates the property at [time] (relative to the clip start).
  double valueAt(Duration time) {
    if (keyframes.isEmpty) return staticValue;
    if (keyframes.length == 1) return keyframes.first.value;

    // Before the first / after the last keyframe the value is clamped, which
    // matches every NLE's behaviour and avoids extrapolation surprises.
    if (time <= keyframes.first.time) return keyframes.first.value;
    if (time >= keyframes.last.time) return keyframes.last.value;

    final i = _segmentIndexFor(time);
    final a = keyframes[i];
    final b = keyframes[i + 1];

    if (a.easing == Easing.hold) return a.value;

    final span = b.time.inMicroseconds - a.time.inMicroseconds;
    if (span <= 0) return b.value;
    final t = (time.inMicroseconds - a.time.inMicroseconds) / span;
    return MathUtils.lerp(a.value, b.value, a.curve.transform(t.clamp(0.0, 1.0)));
  }

  /// Binary search for the segment containing [time].
  /// Linear scanning here showed up in profiles once clips had >50 keyframes
  /// and the renderer evaluated a dozen properties per frame.
  int _segmentIndexFor(Duration time) {
    var lo = 0;
    var hi = keyframes.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (keyframes[mid].time <= time) {
        if (keyframes[mid + 1].time > time) return mid;
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.max(0, math.min(lo, keyframes.length - 2));
  }

  /// Adds or replaces the keyframe at [time], returning a normalised copy.
  AnimatableDouble withKeyframe(Keyframe keyframe) {
    final next = keyframes.where((k) => k.time != keyframe.time).toList()
      ..add(keyframe)
      ..sort((a, b) => a.time.compareTo(b.time));
    return AnimatableDouble(staticValue, keyframes: next);
  }

  AnimatableDouble withoutKeyframeAt(Duration time) => AnimatableDouble(
    staticValue,
    keyframes: keyframes.where((k) => k.time != time).toList(),
  );

  AnimatableDouble clearKeyframes() => AnimatableDouble(staticValue);

  AnimatableDouble withStatic(double value) =>
      AnimatableDouble(value, keyframes: keyframes);

  /// Rescales keyframe times when the clip's speed or duration changes, so
  /// animation stays proportionally where the user put it.
  AnimatableDouble timeScaled(double factor) {
    if (keyframes.isEmpty || (factor - 1.0).abs() < 1e-9) return this;
    return AnimatableDouble(
      staticValue,
      keyframes: keyframes
          .map(
            (k) => k.copyWith(
              time: Duration(microseconds: (k.time.inMicroseconds * factor).round()),
            ),
          )
          .toList(),
    );
  }

  /// Shifts every keyframe in time. Used when a clip is split or trimmed from
  /// the head: the second half's local clock restarts at zero, so its
  /// keyframes must move with it or the animation jumps.
  AnimatableDouble shifted(Duration by) {
    if (keyframes.isEmpty || by == Duration.zero) return this;
    return AnimatableDouble(
      staticValue,
      keyframes: keyframes.map((k) => k.copyWith(time: k.time + by)).toList(),
    );
  }

  /// Drops keyframes outside `[0, limit]` after a trim, keeping the boundary
  /// value by clamping the nearest survivor to the edge.
  AnimatableDouble clampedTo(Duration limit) {
    if (keyframes.isEmpty) return this;
    final kept = keyframes
        .where((k) => k.time >= Duration.zero && k.time <= limit)
        .toList();
    if (kept.isEmpty) {
      return AnimatableDouble(valueAt(Duration.zero));
    }
    return AnimatableDouble(staticValue, keyframes: kept);
  }

  /// Guarantees the sorted, de-duplicated invariant [valueAt] relies on.
  AnimatableDouble normalised() {
    if (keyframes.length < 2) return this;
    final seen = <int>{};
    final sorted = <Keyframe>[];
    for (final k in List<Keyframe>.of(keyframes)
      ..sort((a, b) => a.time.compareTo(b.time))) {
      if (seen.add(k.time.inMicroseconds)) sorted.add(k);
    }
    return AnimatableDouble(staticValue, keyframes: sorted);
  }

  dynamic toJson() {
    // Constant properties serialise as a bare number — the common case, and it
    // keeps project files small enough to diff by eye.
    if (keyframes.isEmpty) return staticValue;
    return {
      's': staticValue,
      'k': keyframes.map((k) => k.toJson()).toList(),
    };
  }

  factory AnimatableDouble.fromJson(dynamic json, {double fallback = 0}) {
    if (json == null) return AnimatableDouble.constant(fallback);
    if (json is num) return AnimatableDouble.constant(json.toDouble());
    if (json is Map) {
      final map = json.cast<String, dynamic>();
      return AnimatableDouble(
        (map['s'] as num?)?.toDouble() ?? fallback,
        keyframes: ((map['k'] as List?) ?? const [])
            .map((e) => Keyframe.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
    }
    return AnimatableDouble.constant(fallback);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnimatableDouble &&
          other.staticValue == staticValue &&
          listEquals(other.keyframes, keyframes);

  @override
  int get hashCode => Object.hash(staticValue, Object.hashAll(keyframes));

  @override
  String toString() => isAnimated
      ? 'Animatable(${keyframes.length} keys)'
      : 'Animatable($staticValue)';
}
