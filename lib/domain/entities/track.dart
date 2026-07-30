/// A horizontal lane of clips.
///
/// Invariant, enforced by every mutator here: `clips` is always sorted by
/// [Clip.start] and never contains two overlapping clips. The timeline engine
/// and the painter both depend on this — the painter binary-searches for the
/// first visible clip, which is only valid on sorted input.
library;

import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import 'clip.dart';
import 'ducking.dart';

enum TrackType {
  video('video'),
  audio('audio'),
  overlay('overlay'),
  text('text'),
  sticker('sticker'),

  /// Holds effects only. Its effects apply to everything composited *below*
  /// it, rather than to media of its own — the standard "adjustment layer".
  adjustment('adjustment');

  const TrackType(this.id);
  final String id;

  static TrackType fromId(String? id) =>
      TrackType.values.firstWhere((e) => e.id == id, orElse: () => TrackType.video);

  bool accepts(ClipKind kind) => switch (this) {
    TrackType.video =>
      kind == ClipKind.video ||
          kind == ClipKind.image ||
          kind == ClipKind.compound,
    TrackType.audio => kind == ClipKind.audio,
    TrackType.overlay =>
      kind == ClipKind.video ||
          kind == ClipKind.image ||
          kind == ClipKind.sticker ||
          kind == ClipKind.compound,
    TrackType.text => kind == ClipKind.text,
    TrackType.sticker => kind == ClipKind.sticker,
    // An adjustment clip is a span with effects on it; an image clip is the
    // simplest carrier we already have, rendered as a pass-through.
    TrackType.adjustment => kind == ClipKind.image,
  };

  /// The track type a clip of [kind] belongs on when auto-placing.
  static TrackType forClipKind(ClipKind kind) => switch (kind) {
    ClipKind.video => TrackType.video,
    ClipKind.image => TrackType.video,
    ClipKind.audio => TrackType.audio,
    ClipKind.text => TrackType.text,
    ClipKind.sticker => TrackType.sticker,
    ClipKind.compound => TrackType.video,
  };

  bool get isVisual => this != TrackType.audio;

  int get colorValue => switch (this) {
    TrackType.video => AppColors.trackVideo.toARGB32(),
    TrackType.audio => AppColors.trackAudio.toARGB32(),
    TrackType.overlay => AppColors.trackOverlay.toARGB32(),
    TrackType.text => AppColors.trackText.toARGB32(),
    TrackType.sticker => AppColors.trackSticker.toARGB32(),
    TrackType.adjustment => AppColors.trackEffect.toARGB32(),
  };

  double get defaultHeight => switch (this) {
    TrackType.video => TimelineMetrics.videoTrackHeight,
    TrackType.overlay => TimelineMetrics.videoTrackHeight,
    TrackType.audio => TimelineMetrics.audioTrackHeight,
    TrackType.text => TimelineMetrics.compactTrackHeight,
    TrackType.sticker => TimelineMetrics.compactTrackHeight,
    TrackType.adjustment => TimelineMetrics.compactTrackHeight,
  };

  String get label => switch (this) {
    TrackType.video => 'Video',
    TrackType.audio => 'Audio',
    TrackType.overlay => 'Overlay',
    TrackType.text => 'Text',
    TrackType.sticker => 'Sticker',
    TrackType.adjustment => 'Adjustment',
  };
}

@immutable
class Track {
  const Track({
    required this.id,
    required this.type,
    this.name = '',
    this.clips = const [],
    this.muted = false,
    this.hidden = false,
    this.locked = false,
    this.volume = 1.0,
    this.solo = false,
    this.heightOverride,
    this.ducking,
  });

  final String id;
  final TrackType type;
  final String name;

  /// Sorted by start time, non-overlapping. See the class doc.
  final List<Clip> clips;

  final bool muted;
  final bool hidden;
  final bool locked;

  /// Track-level gain multiplied with each clip's own volume.
  final double volume;

  /// When any track is soloed, non-soloed audio is silenced.
  final bool solo;

  final double? heightOverride;

  /// Automatic level ducking under another track's audio. Null means off.
  final Ducking? ducking;

  bool get isDucked => ducking?.isActive ?? false;

  double get height => heightOverride ?? type.defaultHeight;

  bool get isEmpty => clips.isEmpty;
  bool get isNotEmpty => clips.isNotEmpty;

  /// Timeline position where this track's content ends.
  Duration get duration =>
      clips.isEmpty ? Duration.zero : clips.last.end;

  String get displayName => name.isNotEmpty ? name : type.label;

  /// The clip covering [time], or null in a gap.
  /// Binary search — this runs once per track per rendered frame.
  Clip? clipAt(Duration time) {
    var lo = 0;
    var hi = clips.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final clip = clips[mid];
      if (time < clip.start) {
        hi = mid - 1;
      } else if (time >= clip.end) {
        lo = mid + 1;
      } else {
        return clip;
      }
    }
    return null;
  }

  Clip? clipById(String clipId) {
    for (final clip in clips) {
      if (clip.id == clipId) return clip;
    }
    return null;
  }

  int indexOfClip(String clipId) =>
      clips.indexWhere((c) => c.id == clipId);

  /// Clips intersecting `[from, to)`, in order. Used by the painter to draw
  /// only what is on screen.
  List<Clip> clipsInRange(Duration from, Duration to) =>
      clips.where((c) => c.start < to && c.end > from).toList();

  /// The clip immediately after [time], if any — used by "next edit" nav.
  Clip? nextClipAfter(Duration time) {
    for (final clip in clips) {
      if (clip.start > time) return clip;
    }
    return null;
  }

  Clip? previousClipBefore(Duration time) {
    Clip? found;
    for (final clip in clips) {
      if (clip.end < time) {
        found = clip;
      } else {
        break;
      }
    }
    return found;
  }

  /// Free interval starting at [from] before the next clip begins.
  /// `null` upper bound means "unbounded".
  (Duration start, Duration? end) gapAt(Duration from) {
    for (final clip in clips) {
      if (clip.end <= from) continue;
      if (clip.start > from) return (from, clip.start);
      return (clip.end, nextClipAfter(clip.end)?.start);
    }
    return (from, null);
  }

  /// True when [candidate] would collide with an existing clip.
  /// [ignoreClipId] lets a clip be tested against its own future position.
  ///
  /// One overlap is legal: a clip may extend into its predecessor by exactly
  /// that predecessor's transition duration. That overlap *is* the transition —
  /// a cross-dissolve has to consume material from both sides, so adding one
  /// necessarily pulls the incoming clip earlier. Treating it as a collision
  /// would make transitions impossible to represent.
  bool hasCollision(Clip candidate, {String? ignoreClipId}) {
    for (final clip in clips) {
      if (clip.id == candidate.id || clip.id == ignoreClipId) continue;
      if (!clip.overlaps(candidate)) continue;
      if (_isSanctionedTransitionOverlap(clip, candidate)) continue;
      return true;
    }
    return false;
  }

  static bool _isSanctionedTransitionOverlap(Clip a, Clip b) {
    final (first, second) = a.start <= b.start ? (a, b) : (b, a);
    final transition = first.outTransition;
    if (transition == null || !transition.isActive) return false;
    final overlap = first.end - second.start;
    return overlap > Duration.zero && overlap <= transition.duration;
  }

  /// End of the track's content, accounting for transition overlaps.
  Duration get renderedDuration {
    if (clips.isEmpty) return Duration.zero;
    var end = Duration.zero;
    for (final clip in clips) {
      if (clip.end > end) end = clip.end;
    }
    return end;
  }

  // ── Mutators (all return a new Track, preserving the sort invariant) ──

  Track withClips(List<Clip> next) {
    final sorted = List<Clip>.of(next)
      ..sort((a, b) => a.start.compareTo(b.start));
    return copyWith(clips: sorted);
  }

  Track addClip(Clip clip) => withClips([...clips, clip]);

  Track removeClip(String clipId) =>
      copyWith(clips: clips.where((c) => c.id != clipId).toList());

  Track replaceClip(Clip clip) {
    final index = indexOfClip(clip.id);
    if (index < 0) return this;
    final next = List<Clip>.of(clips)..[index] = clip;
    // Replacing can move a clip, so re-sort rather than assume order held.
    return withClips(next);
  }

  Track copyWith({
    String? id,
    TrackType? type,
    String? name,
    List<Clip>? clips,
    bool? muted,
    bool? hidden,
    bool? locked,
    double? volume,
    bool? solo,
    double? heightOverride,
    Ducking? ducking,
    bool clearDucking = false,
  }) => Track(
    id: id ?? this.id,
    type: type ?? this.type,
    name: name ?? this.name,
    clips: clips ?? this.clips,
    muted: muted ?? this.muted,
    hidden: hidden ?? this.hidden,
    locked: locked ?? this.locked,
    volume: volume ?? this.volume,
    solo: solo ?? this.solo,
    heightOverride: heightOverride ?? this.heightOverride,
    ducking: clearDucking ? null : (ducking ?? this.ducking),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.id,
    if (name.isNotEmpty) 'name': name,
    'clips': clips.map((c) => c.toJson()).toList(),
    if (muted) 'muted': true,
    if (hidden) 'hidden': true,
    if (locked) 'locked': true,
    if (volume != 1.0) 'volume': volume,
    if (solo) 'solo': true,
    if (heightOverride != null) 'height': heightOverride,
    if (ducking != null) 'duck': ducking!.toJson(),
  };

  factory Track.fromJson(Map<String, dynamic> json) {
    final clips = ((json['clips'] as List?) ?? const [])
        .map((e) => Clip.fromJson((e as Map).cast<String, dynamic>()))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return Track(
      id: json['id'] as String,
      type: TrackType.fromId(json['type'] as String?),
      name: json['name'] as String? ?? '',
      clips: clips,
      muted: json['muted'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      locked: json['locked'] as bool? ?? false,
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      solo: json['solo'] as bool? ?? false,
      heightOverride: (json['height'] as num?)?.toDouble(),
      ducking: Ducking.fromJson((json['duck'] as Map?)?.cast<String, dynamic>()),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Track($id, ${type.id}, ${clips.length} clips)';
}
