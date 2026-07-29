/// A transition between two adjacent clips on the same track.
///
/// Transitions are stored on the *outgoing* clip. That single choice removes a
/// whole class of bugs: deleting a clip cannot leave an orphaned transition
/// pointing at a missing neighbour, because the transition dies with its owner.
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import 'keyframe.dart';

enum TransitionType {
  none('none'),
  fade('fade'),
  zoom('zoom'),
  slide('slide'),
  flash('flash'),
  spin('spin'),
  blur('blur'),
  glitch('glitch'),
  warp('warp'),
  ripple('ripple'),
  push('push');

  const TransitionType(this.id);
  final String id;

  static TransitionType fromId(String? id) => TransitionType.values.firstWhere(
    (e) => e.id == id,
    orElse: () => TransitionType.none,
  );

  /// Directional transitions expose a direction control in the inspector.
  bool get isDirectional =>
      this == TransitionType.slide ||
      this == TransitionType.push ||
      this == TransitionType.warp;
}

enum TransitionDirection {
  left('left'),
  right('right'),
  up('up'),
  down('down');

  const TransitionDirection(this.id);
  final String id;

  static TransitionDirection fromId(String? id) =>
      TransitionDirection.values.firstWhere(
        (e) => e.id == id,
        orElse: () => TransitionDirection.left,
      );
}

@immutable
class Transition {
  const Transition({
    required this.id,
    required this.type,
    this.duration = AppConstants.defaultTransitionDuration,
    this.direction = TransitionDirection.left,
    this.easing = Easing.easeInOut,
    this.intensity = 1.0,
  });

  final String id;
  final TransitionType type;

  /// Total overlap. The two clips each contribute half of this, so a 600ms
  /// transition pulls the incoming clip 300ms earlier on the timeline.
  final Duration duration;

  final TransitionDirection direction;
  final Easing easing;

  /// 0..1 strength for the transitions that have one (glitch, ripple, warp).
  final double intensity;

  bool get isActive => type != TransitionType.none && duration > Duration.zero;

  /// How much earlier the incoming clip must start for the overlap to exist.
  Duration get overlap => isActive ? duration : Duration.zero;

  /// Progress 0..1 through the transition at [elapsed], with easing applied.
  double progressAt(Duration elapsed) {
    if (!isActive) return 1;
    final raw = elapsed.inMicroseconds / duration.inMicroseconds;
    return easing.curve.transform(raw.clamp(0.0, 1.0));
  }

  Transition copyWith({
    String? id,
    TransitionType? type,
    Duration? duration,
    TransitionDirection? direction,
    Easing? easing,
    double? intensity,
  }) => Transition(
    id: id ?? this.id,
    type: type ?? this.type,
    duration: duration ?? this.duration,
    direction: direction ?? this.direction,
    easing: easing ?? this.easing,
    intensity: intensity ?? this.intensity,
  );

  /// Clamps the duration so the transition can never be longer than the
  /// shorter of the two clips it joins — otherwise the overlap would consume a
  /// clip entirely and the render would drop frames.
  Transition clampedTo(Duration outgoingLength, Duration incomingLength) {
    final maxByClips = Duration(
      microseconds:
          (outgoingLength.inMicroseconds < incomingLength.inMicroseconds
                  ? outgoingLength.inMicroseconds
                  : incomingLength.inMicroseconds) ~/
              2,
    );
    final cap = maxByClips < AppConstants.maxTransitionDuration
        ? maxByClips
        : AppConstants.maxTransitionDuration;
    return duration <= cap ? this : copyWith(duration: cap);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.id,
    'durUs': duration.inMicroseconds,
    if (type.isDirectional) 'dir': direction.id,
    'easing': easing.id,
    if (intensity != 1.0) 'intensity': intensity,
  };

  factory Transition.fromJson(Map<String, dynamic> json) => Transition(
    id: json['id'] as String,
    type: TransitionType.fromId(json['type'] as String?),
    duration: Duration(
      microseconds: (json['durUs'] as num?)?.toInt() ??
          AppConstants.defaultTransitionDuration.inMicroseconds,
    ),
    direction: TransitionDirection.fromId(json['dir'] as String?),
    easing: Easing.fromId(json['easing'] as String?),
    intensity: (json['intensity'] as num?)?.toDouble() ?? 1.0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Transition && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Transition(${type.id}, ${duration.inMilliseconds}ms)';
}
