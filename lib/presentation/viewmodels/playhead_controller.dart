/// Playhead position and transport state.
///
/// Isolated from [EditorState] on purpose: this changes every frame during
/// playback, and widgets that only care about the *structure* of the timeline
/// must not rebuild 60 times a second.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/time_utils.dart';

@immutable
class PlayheadState {
  const PlayheadState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.rate = 1.0,
    this.looping = false,
    this.isScrubbing = false,
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double rate;
  final bool looping;

  /// True while the user drags the playhead. The preview drops to a lower
  /// quality path in this state so scrubbing stays responsive.
  final bool isScrubbing;

  double get progress => duration <= Duration.zero
      ? 0
      : (position.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

  bool get isAtEnd => duration > Duration.zero && position >= duration;

  PlayheadState copyWith({
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    double? rate,
    bool? looping,
    bool? isScrubbing,
  }) => PlayheadState(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    isPlaying: isPlaying ?? this.isPlaying,
    rate: rate ?? this.rate,
    looping: looping ?? this.looping,
    isScrubbing: isScrubbing ?? this.isScrubbing,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayheadState &&
          other.position == position &&
          other.duration == duration &&
          other.isPlaying == isPlaying &&
          other.rate == rate &&
          other.looping == looping &&
          other.isScrubbing == isScrubbing;

  @override
  int get hashCode =>
      Object.hash(position, duration, isPlaying, rate, looping, isScrubbing);
}

final playheadControllerProvider =
    NotifierProvider<PlayheadController, PlayheadState>(
      PlayheadController.new,
    );

class PlayheadController extends Notifier<PlayheadState> {
  @override
  PlayheadState build() => const PlayheadState();

  /// Frame rate of the open project; seeks snap to it.
  int fps = 30;

  void setDuration(Duration duration) {
    state = state.copyWith(
      duration: duration,
      position: state.position > duration ? duration : state.position,
    );
  }

  void seek(Duration position, {bool snapToFrame = true}) {
    final clamped = TimeUtils.clamp(position, Duration.zero, state.duration);
    state = state.copyWith(
      position: snapToFrame ? TimeUtils.snapToFrame(clamped, fps) : clamped,
    );
  }

  /// Called by the ticker during playback. Skips frame snapping — the position
  /// is already continuous and snapping it would quantise smooth motion.
  void tick(Duration position) {
    state = state.copyWith(position: position);
  }

  void seekBy(Duration delta) => seek(state.position + delta);

  void stepFrames(int frames) =>
      seek(state.position + TimeUtils.frameToDuration(frames, fps));

  /// Jumps to the next or previous clip boundary.
  void jumpToEditPoint(List<Duration> editPoints, {required bool forward}) {
    if (editPoints.isEmpty) return;
    if (forward) {
      for (final point in editPoints) {
        if (point > state.position) return seek(point);
      }
      seek(state.duration);
    } else {
      for (final point in editPoints.reversed) {
        if (point < state.position) return seek(point);
      }
      seek(Duration.zero);
    }
  }

  void play() {
    if (state.isAtEnd) seek(Duration.zero);
    state = state.copyWith(isPlaying: true);
  }

  void pause() => state = state.copyWith(isPlaying: false);

  void togglePlay() => state.isPlaying ? pause() : play();

  void setRate(double rate) =>
      state = state.copyWith(rate: rate.clamp(0.25, 4.0));

  void toggleLoop() => state = state.copyWith(looping: !state.looping);

  void beginScrub() =>
      state = state.copyWith(isScrubbing: true, isPlaying: false);

  void endScrub() => state = state.copyWith(isScrubbing: false);
}
