/// The composition: an ordered stack of tracks plus canvas settings.
///
/// Track order is z-order for visual tracks — index 0 is the bottom layer, and
/// later tracks composite over it. That matches how the layer list reads in the
/// UI once it is drawn top-down.
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/math_utils.dart';
import '../../core/utils/time_utils.dart';
import 'clip.dart';
import 'track.dart';

/// Canvas shape presets offered when creating a project.
enum AspectPreset {
  vertical9x16('9:16', 1080, 1920),
  square1x1('1:1', 1080, 1080),
  horizontal16x9('16:9', 1920, 1080),
  portrait4x5('4:5', 1080, 1350),
  classic4x3('4:3', 1440, 1080),
  cinema21x9('21:9', 2560, 1080),
  custom('Custom', 1080, 1920);

  const AspectPreset(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;

  static AspectPreset fromLabel(String? label) => AspectPreset.values
      .firstWhere((e) => e.label == label, orElse: () => AspectPreset.vertical9x16);

  double get ratio => width / height;
}

@immutable
class Timeline {
  const Timeline({
    this.tracks = const [],
    this.fps = AppConstants.defaultFps,
    this.width = AppConstants.defaultWidth,
    this.height = AppConstants.defaultHeight,
    this.backgroundColor = 0xFF000000,
    this.aspectPreset = AspectPreset.vertical9x16,
  });

  final List<Track> tracks;

  /// Project frame rate. Every edit snaps to this grid.
  final int fps;

  final int width;
  final int height;

  /// ARGB fill behind all layers — visible wherever a clip is letterboxed.
  final int backgroundColor;

  final AspectPreset aspectPreset;

  /// End of the last clip on any track.
  Duration get duration {
    var longest = Duration.zero;
    for (final track in tracks) {
      final end = track.duration;
      if (end > longest) longest = end;
    }
    return longest;
  }

  double get aspectRatio => height == 0 ? 9 / 16 : width / height;

  String get resolutionLabel => '$width×$height';

  String get aspectLabel => MathUtils.aspectRatioLabel(width, height);

  bool get isEmpty => tracks.every((t) => t.isEmpty);

  int get clipCount =>
      tracks.fold(0, (sum, track) => sum + track.clips.length);

  /// Visual tracks bottom-to-top — the compositing order.
  List<Track> get visualTracks =>
      tracks.where((t) => t.type.isVisual && !t.hidden).toList();

  List<Track> get audioTracks =>
      tracks.where((t) => t.type == TrackType.audio).toList();

  bool get hasSoloedTrack => tracks.any((t) => t.solo);

  /// True when [track] should be audible given the current mute/solo state.
  bool isTrackAudible(Track track) {
    if (track.muted) return false;
    if (hasSoloedTrack && !track.solo) return false;
    return true;
  }

  Track? trackById(String trackId) {
    for (final track in tracks) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  int indexOfTrack(String trackId) => tracks.indexWhere((t) => t.id == trackId);

  /// Locates a clip anywhere in the timeline.
  (Track track, Clip clip)? findClip(String clipId) {
    for (final track in tracks) {
      final clip = track.clipById(clipId);
      if (clip != null) return (track, clip);
    }
    return null;
  }

  /// Every clip visible at [time], bottom layer first.
  List<Clip> visualClipsAt(Duration time) {
    final result = <Clip>[];
    for (final track in visualTracks) {
      final clip = track.clipAt(time);
      if (clip != null && clip.enabled) result.add(clip);
    }
    return result;
  }

  /// Every audible clip at [time].
  List<Clip> audioClipsAt(Duration time) {
    final result = <Clip>[];
    for (final track in tracks) {
      if (!isTrackAudible(track)) continue;
      final clip = track.clipAt(time);
      if (clip == null || !clip.enabled) continue;
      if (clip is AudioClip || (clip is VideoClip && !clip.muted)) {
        result.add(clip);
      }
    }
    return result;
  }

  /// All clip boundaries, sorted — the snap targets and the "jump to next cut"
  /// destinations.
  List<Duration> get editPoints {
    final points = <int>{0};
    for (final track in tracks) {
      for (final clip in track.clips) {
        points.add(clip.start.inMicroseconds);
        points.add(clip.end.inMicroseconds);
      }
    }
    final sorted = points.toList()..sort();
    return sorted.map((us) => Duration(microseconds: us)).toList();
  }

  // ── Mutators ─────────────────────────────────────────────────────────

  Timeline withTracks(List<Track> next) => copyWith(tracks: next);

  Timeline addTrack(Track track) => copyWith(tracks: [...tracks, track]);

  Timeline removeTrack(String trackId) =>
      copyWith(tracks: tracks.where((t) => t.id != trackId).toList());

  Timeline replaceTrack(Track track) {
    final index = indexOfTrack(track.id);
    if (index < 0) return this;
    final next = List<Track>.of(tracks)..[index] = track;
    return copyWith(tracks: next);
  }

  /// Applies [transform] to the track owning [clipId].
  Timeline updateTrackOf(String clipId, Track Function(Track track) transform) {
    final found = findClip(clipId);
    if (found == null) return this;
    return replaceTrack(transform(found.$1));
  }

  Timeline moveTrack(int from, int to) {
    if (from < 0 || from >= tracks.length) return this;
    final clampedTo = MathUtils.clampInt(to, 0, tracks.length - 1);
    final next = List<Track>.of(tracks);
    final track = next.removeAt(from);
    next.insert(clampedTo, track);
    return copyWith(tracks: next);
  }

  /// Rounds every clip boundary onto the frame grid. Run after changing [fps]
  /// so a project converted from 30 → 24 fps has no sub-frame edits left.
  Timeline snappedToFrameGrid() => copyWith(
    tracks: tracks
        .map(
          (track) => track.withClips(
            track.clips
                .map(
                  (clip) => clip.copyWithBase(
                    start: TimeUtils.snapToFrame(clip.start, fps),
                    duration: TimeUtils.max(
                      TimeUtils.snapToFrame(clip.duration, fps),
                      TimeUtils.frameToDuration(1, fps),
                    ),
                  ),
                )
                .toList(),
          ),
        )
        .toList(),
  );

  Timeline copyWith({
    List<Track>? tracks,
    int? fps,
    int? width,
    int? height,
    int? backgroundColor,
    AspectPreset? aspectPreset,
  }) => Timeline(
    tracks: tracks ?? this.tracks,
    fps: fps ?? this.fps,
    width: width ?? this.width,
    height: height ?? this.height,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    aspectPreset: aspectPreset ?? this.aspectPreset,
  );

  Map<String, dynamic> toJson() => {
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'fps': fps,
    'w': width,
    'h': height,
    'bg': backgroundColor,
    'aspect': aspectPreset.label,
  };

  factory Timeline.fromJson(Map<String, dynamic> json) => Timeline(
    tracks: ((json['tracks'] as List?) ?? const [])
        .map((e) => Track.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    fps: (json['fps'] as num?)?.toInt() ?? AppConstants.defaultFps,
    width: (json['w'] as num?)?.toInt() ?? AppConstants.defaultWidth,
    height: (json['h'] as num?)?.toInt() ?? AppConstants.defaultHeight,
    backgroundColor: (json['bg'] as num?)?.toInt() ?? 0xFF000000,
    aspectPreset: AspectPreset.fromLabel(json['aspect'] as String?),
  );

  @override
  String toString() =>
      'Timeline(${tracks.length} tracks, $clipCount clips, '
      '${duration.inMilliseconds}ms @ ${fps}fps)';
}
