/// A named point on the timeline.
///
/// Markers are navigation and communication, not content: they never render.
/// They act as snap targets, jump destinations, and — for a long edit — the
/// chapter list the user thinks in.
library;

import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';

enum MarkerKind {
  /// A plain point of interest.
  note('note'),

  /// A structural division — the chapter list is built from these.
  chapter('chapter'),

  /// Something to come back to. Surfaced in a "to do" list.
  todo('todo'),

  /// Placed automatically by beat detection.
  beat('beat');

  const MarkerKind(this.id);
  final String id;

  static MarkerKind fromId(String? id) =>
      MarkerKind.values.firstWhere((e) => e.id == id, orElse: () => MarkerKind.note);

  int get colorValue => switch (this) {
    MarkerKind.note => AppColors.info.toARGB32(),
    MarkerKind.chapter => AppColors.brandViolet.toARGB32(),
    MarkerKind.todo => AppColors.warning.toARGB32(),
    MarkerKind.beat => AppColors.brandCyan.toARGB32(),
  };

  String get label => switch (this) {
    MarkerKind.note => 'Note',
    MarkerKind.chapter => 'Chapter',
    MarkerKind.todo => 'To do',
    MarkerKind.beat => 'Beat',
  };
}

@immutable
class Marker {
  const Marker({
    required this.id,
    required this.time,
    this.label = '',
    this.kind = MarkerKind.note,
  });

  final String id;
  final Duration time;
  final String label;
  final MarkerKind kind;

  String get displayLabel => label.isNotEmpty ? label : kind.label;

  /// Beat markers arrive in the hundreds, so they are drawn as thin ticks and
  /// excluded from the chapter list.
  bool get isDense => kind == MarkerKind.beat;

  Marker copyWith({Duration? time, String? label, MarkerKind? kind}) => Marker(
    id: id,
    time: time ?? this.time,
    label: label ?? this.label,
    kind: kind ?? this.kind,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'tUs': time.inMicroseconds,
    if (label.isNotEmpty) 'label': label,
    'kind': kind.id,
  };

  factory Marker.fromJson(Map<String, dynamic> json) => Marker(
    id: json['id'] as String,
    time: Duration(microseconds: (json['tUs'] as num?)?.toInt() ?? 0),
    label: json['label'] as String? ?? '',
    kind: MarkerKind.fromId(json['kind'] as String?),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Marker && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Marker(${kind.id} @ ${time.inMilliseconds}ms)';
}
