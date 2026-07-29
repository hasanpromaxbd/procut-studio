import 'dart:async';
import 'dart:ui';

/// Collapses a burst of calls into one trailing call.
/// Used by auto-save so a drag gesture writes once, not per frame.
class Debouncer {
  Debouncer(this.duration);

  final Duration duration;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(duration, action);
  }

  /// Runs the pending action immediately, if any is queued.
  void flush(VoidCallback action) {
    if (isPending) {
      _timer?.cancel();
      _timer = null;
      action();
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// Guarantees at most one call per [duration], executing the first immediately.
/// Used for scrub-driven preview seeks, where the trailing call of a debouncer
/// would make the preview feel laggy.
class Throttler {
  Throttler(this.duration);

  final Duration duration;
  DateTime? _lastRun;
  Timer? _trailingTimer;

  void run(VoidCallback action, {bool trailing = true}) {
    final now = DateTime.now();
    final last = _lastRun;
    if (last == null || now.difference(last) >= duration) {
      _lastRun = now;
      action();
      return;
    }
    if (!trailing) return;
    _trailingTimer?.cancel();
    _trailingTimer = Timer(duration - now.difference(last), () {
      _lastRun = DateTime.now();
      action();
    });
  }

  void cancel() {
    _trailingTimer?.cancel();
    _trailingTimer = null;
  }

  void dispose() => cancel();
}

/// Serialises async work so only the newest request survives.
///
/// The preview compositor uses this: if the user scrubs while a frame decode
/// is in flight, the intermediate positions are dropped and only the latest
/// one is rendered, which is what keeps scrubbing responsive.
class LatestOnlyRunner<T> {
  Future<T>? _inFlight;
  Future<T> Function()? _queued;
  bool _disposed = false;

  Future<void> submit(Future<T> Function() task) async {
    if (_disposed) return;
    if (_inFlight != null) {
      _queued = task; // replaces any previously queued task
      return;
    }
    _inFlight = task();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
    }
    final next = _queued;
    if (next != null && !_disposed) {
      _queued = null;
      await submit(next);
    }
  }

  void dispose() {
    _disposed = true;
    _queued = null;
  }
}
