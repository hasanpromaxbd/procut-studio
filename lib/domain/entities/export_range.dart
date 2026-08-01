/// A window of the timeline to render, instead of the whole thing.
///
/// Exists so a range export is provably *the same edit*, just shorter: the
/// compiler builds the full graph and trims only its tail, rather than
/// building a different, shorter timeline. Placement, speed, automation and
/// transitions are therefore identical to what a full render would produce.
library;

import 'package:flutter/foundation.dart';

@immutable
class ExportRange {
  const ExportRange({required this.start, required this.end});

  /// A window of [length] beginning at [at] — the test-render shape.
  factory ExportRange.around(Duration at, {required Duration length}) {
    final from = at < Duration.zero ? Duration.zero : at;
    return ExportRange(start: from, end: from + length);
  }

  final Duration start;
  final Duration end;

  Duration get duration => end - start;
  bool get isEmpty => duration <= Duration.zero;

  /// Clipped to a timeline of [total], or null when nothing survives.
  ExportRange? clampedTo(Duration total) {
    final from = start < Duration.zero ? Duration.zero : start;
    final to = end > total ? total : end;
    if (to <= from) return null;
    // A window covering everything is not a window; returning null keeps the
    // graph free of a trim that would only cost time.
    if (from == Duration.zero && to == total) return null;
    return ExportRange(start: from, end: to);
  }

  @override
  bool operator ==(Object other) =>
      other is ExportRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ExportRange(${start.inMilliseconds}'
      '–${end.inMilliseconds}ms)';
}
