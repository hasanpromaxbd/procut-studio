/// Drives the playhead at display refresh rate.
///
/// The clock is a [Ticker], not a `Timer.periodic`. A periodic timer fires on
/// the event loop and is not aligned to vsync, so the playhead drifts against
/// the rendered frames and the timeline visibly stutters. A ticker is called by
/// the engine once per frame with a monotonic elapsed time, which is exactly
/// what a playhead wants.
library;

import 'package:flutter/scheduler.dart';

import '../../core/utils/time_utils.dart';

typedef PlayheadListener = void Function(Duration position);

class PlaybackClock {
  PlaybackClock({required TickerProvider vsync, this.onTick}) {
    _ticker = vsync.createTicker(_handleTick);
  }

  late final Ticker _ticker;

  /// Called every frame while playing.
  PlayheadListener? onTick;

  /// Fired once when the playhead reaches [duration].
  VoidCallback? onCompleted;

  Duration _position = Duration.zero;
  /// Timeline length. Set by the editor whenever the timeline changes.
  Duration duration = Duration.zero;

  Duration _tickerBase = Duration.zero;
  double _rate = 1.0;
  /// Restart from zero on reaching the end.
  bool looping = false;

  Duration get position => _position;
  bool get isPlaying => _ticker.isActive;
  double get rate => _rate;

  /// 0..1 through the timeline.
  double get progress => duration <= Duration.zero
      ? 0
      : (_position.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

  /// Playback speed multiplier for preview scrubbing (0.25×–4×).
  set rate(double value) {
    // Rebase so the change takes effect from *now* rather than retroactively
    // rescaling everything played so far.
    if (_ticker.isActive) {
      _tickerBase = _lastTickerElapsed;
      _anchor = _position;
    }
    _rate = value.clamp(0.1, 4.0);
  }

  Duration _lastTickerElapsed = Duration.zero;
  Duration _anchor = Duration.zero;

  void play() {
    if (_ticker.isActive) return;
    if (duration > Duration.zero && _position >= duration) {
      _position = Duration.zero;
    }
    _anchor = _position;
    _tickerBase = Duration.zero;
    _lastTickerElapsed = Duration.zero;
    _ticker.start();
  }

  void pause() {
    if (!_ticker.isActive) return;
    _ticker.stop();
  }

  void toggle() => isPlaying ? pause() : play();

  /// Moves the playhead without changing play state.
  void seek(Duration position, {int? fps}) {
    final clamped = TimeUtils.clamp(
      position,
      Duration.zero,
      duration <= Duration.zero ? position : duration,
    );
    _position = fps == null ? clamped : TimeUtils.snapToFrame(clamped, fps);
    if (_ticker.isActive) {
      _anchor = _position;
      _tickerBase = _lastTickerElapsed;
    }
    onTick?.call(_position);
  }

  void seekBy(Duration delta, {int? fps}) => seek(_position + delta, fps: fps);

  /// Steps exactly one frame. The reason [seek] takes an fps at all: stepping
  /// by "33ms" accumulates rounding error and lands between frames.
  void stepFrames(int frames, int fps) =>
      seek(_position + TimeUtils.frameToDuration(frames, fps), fps: fps);

  void _handleTick(Duration elapsed) {
    _lastTickerElapsed = elapsed;
    final delta = elapsed - _tickerBase;
    final scaled = Duration(
      microseconds: (delta.inMicroseconds * _rate).round(),
    );
    var next = _anchor + scaled;

    if (duration > Duration.zero && next >= duration) {
      if (looping) {
        next = Duration.zero;
        _anchor = Duration.zero;
        _tickerBase = elapsed;
      } else {
        next = duration;
        _position = next;
        onTick?.call(_position);
        pause();
        onCompleted?.call();
        return;
      }
    }

    _position = next;
    onTick?.call(_position);
  }

  void dispose() {
    _ticker
      ..stop()
      ..dispose();
  }
}
