/// A saved editing session: the timeline plus the assets it references.
///
/// Assets are stored *inside* the project rather than in a global library so a
/// project is self-describing — exporting one and importing it on another
/// device only needs the media files, not a shared database.
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import 'clip.dart';
import 'media_asset.dart';
import 'timeline.dart';
import 'track.dart';

@immutable
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.timeline,
    required this.createdAt,
    required this.updatedAt,
    this.assets = const {},
    this.thumbnailPath,
    this.schemaVersion = AppConstants.projectSchemaVersion,
    this.lastExportPath,
    this.lastPlayheadUs = 0,
  });

  /// A brand-new project with one video track and one audio track — the
  /// minimum that makes the timeline usable without the user creating layers.
  factory Project.empty({
    required String id,
    required String name,
    required String videoTrackId,
    required String audioTrackId,
    AspectPreset aspect = AspectPreset.vertical9x16,
    int fps = AppConstants.defaultFps,
  }) {
    final now = DateTime.now();
    return Project(
      id: id,
      name: name,
      createdAt: now,
      updatedAt: now,
      timeline: Timeline(
        fps: fps,
        width: aspect.width,
        height: aspect.height,
        aspectPreset: aspect,
        tracks: [
          Track(id: videoTrackId, type: TrackType.video, name: 'Video 1'),
          Track(id: audioTrackId, type: TrackType.audio, name: 'Audio 1'),
        ],
      ),
    );
  }

  final String id;
  final String name;
  final Timeline timeline;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Asset id → asset. Clips hold only ids.
  final Map<String, MediaAsset> assets;

  /// Poster frame shown on the home screen card.
  final String? thumbnailPath;

  final int schemaVersion;
  final String? lastExportPath;

  /// Where the playhead was when the project was last closed, so reopening
  /// resumes in place.
  final int lastPlayheadUs;

  Duration get duration => timeline.duration;
  Duration get lastPlayhead => Duration(microseconds: lastPlayheadUs);

  bool get isEmpty => timeline.isEmpty;
  int get clipCount => timeline.clipCount;
  int get trackCount => timeline.tracks.length;

  MediaAsset? asset(String assetId) => assets[assetId];

  /// Asset ids referenced by at least one clip. Anything not in this set is
  /// dead weight and can be pruned on save.
  Set<String> get referencedAssetIds {
    final ids = <String>{};
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (clip is MediaClip) ids.add(clip.assetId);
      }
    }
    return ids;
  }

  /// Assets whose backing file has gone missing (moved, deleted, or on a
  /// revoked SAF grant). The editor surfaces these as "relink" prompts rather
  /// than failing at export time.
  List<MediaAsset> missingAssets(bool Function(String path) existsSync) =>
      assets.values.where((a) => !existsSync(a.path)).toList();

  Project touch() => copyWith(updatedAt: DateTime.now());

  Project withTimeline(Timeline next) =>
      copyWith(timeline: next, updatedAt: DateTime.now());

  Project withAsset(MediaAsset asset) => copyWith(
    assets: {...assets, asset.id: asset},
    updatedAt: DateTime.now(),
  );

  Project withAssets(Iterable<MediaAsset> incoming) => copyWith(
    assets: {...assets, for (final a in incoming) a.id: a},
    updatedAt: DateTime.now(),
  );

  /// Drops assets no clip refers to any more.
  Project pruneAssets() {
    final referenced = referencedAssetIds;
    if (referenced.length == assets.length) return this;
    return copyWith(
      assets: {
        for (final entry in assets.entries)
          if (referenced.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  Project copyWith({
    String? id,
    String? name,
    Timeline? timeline,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, MediaAsset>? assets,
    String? thumbnailPath,
    int? schemaVersion,
    String? lastExportPath,
    int? lastPlayheadUs,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    timeline: timeline ?? this.timeline,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    assets: assets ?? this.assets,
    thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    lastExportPath: lastExportPath ?? this.lastExportPath,
    lastPlayheadUs: lastPlayheadUs ?? this.lastPlayheadUs,
  );

  Map<String, dynamic> toJson() => {
    'schema': schemaVersion,
    'id': id,
    'name': name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'timeline': timeline.toJson(),
    'assets': assets.map((k, v) => MapEntry(k, v.toJson())),
    if (thumbnailPath != null) 'thumb': thumbnailPath,
    if (lastExportPath != null) 'lastExport': lastExportPath,
    if (lastPlayheadUs != 0) 'playheadUs': lastPlayheadUs,
  };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Untitled',
    timeline: Timeline.fromJson(
      ((json['timeline'] as Map?) ?? const {}).cast<String, dynamic>(),
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num?)?.toInt() ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as num?)?.toInt() ?? 0,
    ),
    assets: ((json['assets'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(
        k as String,
        MediaAsset.fromJson((v as Map).cast<String, dynamic>()),
      ),
    ),
    thumbnailPath: json['thumb'] as String?,
    schemaVersion: (json['schema'] as num?)?.toInt() ?? 1,
    lastExportPath: json['lastExport'] as String?,
    lastPlayheadUs: (json['playheadUs'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Project && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Project($id, "$name", $clipCount clips)';
}

/// Lightweight row for the home screen. Loading 200 full projects to render a
/// grid of cards would deserialise every clip for nothing.
@immutable
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.duration,
    required this.clipCount,
    this.thumbnailPath,
    this.width = 0,
    this.height = 0,
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final Duration duration;
  final int clipCount;
  final String? thumbnailPath;
  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 9 / 16 : width / height;

  factory ProjectSummary.fromProject(Project project) => ProjectSummary(
    id: project.id,
    name: project.name,
    updatedAt: project.updatedAt,
    duration: project.duration,
    clipCount: project.clipCount,
    thumbnailPath: project.thumbnailPath,
    width: project.timeline.width,
    height: project.timeline.height,
  );

  /// Builds a summary without fully materialising the timeline — only the
  /// fields the card needs are walked.
  factory ProjectSummary.fromJson(Map<String, dynamic> json) {
    final timeline = (json['timeline'] as Map?)?.cast<String, dynamic>();
    var clipCount = 0;
    var maxEndUs = 0;
    for (final rawTrack in (timeline?['tracks'] as List?) ?? const []) {
      for (final rawClip in ((rawTrack as Map)['clips'] as List?) ?? const []) {
        clipCount++;
        final clip = (rawClip as Map);
        final end = ((clip['startUs'] as num?)?.toInt() ?? 0) +
            ((clip['durUs'] as num?)?.toInt() ?? 0);
        if (end > maxEndUs) maxEndUs = end;
      }
    }
    return ProjectSummary(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      duration: Duration(microseconds: maxEndUs),
      clipCount: clipCount,
      thumbnailPath: json['thumb'] as String?,
      width: (timeline?['w'] as num?)?.toInt() ?? 0,
      height: (timeline?['h'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProjectSummary && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
