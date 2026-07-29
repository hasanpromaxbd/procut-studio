/// A saved edit structure with the media removed.
///
/// A template keeps everything that took effort to build — cut rhythm,
/// transitions, effects, titles, keyframes — and replaces each media clip with
/// a **slot** describing what belongs there. Applying it drops new footage into
/// those slots, retimed to fit.
///
/// The slot is the whole idea: without it a template is just a project copy,
/// and the user has to relink every clip by hand.
library;

import 'package:flutter/foundation.dart';

import '../../core/utils/id_generator.dart';
import '../../core/utils/time_utils.dart';
import 'clip.dart';
import 'media_asset.dart';
import 'project.dart';
import 'timeline.dart';

@immutable
class TemplateSlot {
  const TemplateSlot({
    required this.clipId,
    required this.trackId,
    required this.start,
    required this.duration,
    required this.kind,
    this.label = '',
  });

  final String clipId;
  final String trackId;
  final Duration start;
  final Duration duration;
  final ClipKind kind;

  /// What the user should put here — "opening shot", "b-roll".
  final String label;

  bool accepts(AssetKind assetKind) => switch (kind) {
    ClipKind.video => assetKind == AssetKind.video,
    ClipKind.image => assetKind == AssetKind.image,
    ClipKind.audio => assetKind == AssetKind.audio,
    ClipKind.text || ClipKind.sticker => false,
  };

  Map<String, dynamic> toJson() => {
    'clipId': clipId,
    'trackId': trackId,
    'startUs': start.inMicroseconds,
    'durUs': duration.inMicroseconds,
    'kind': kind.id,
    if (label.isNotEmpty) 'label': label,
  };

  factory TemplateSlot.fromJson(Map<String, dynamic> json) => TemplateSlot(
    clipId: json['clipId'] as String,
    trackId: json['trackId'] as String,
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    duration: Duration(microseconds: (json['durUs'] as num?)?.toInt() ?? 0),
    kind: ClipKind.fromId(json['kind'] as String?),
    label: json['label'] as String? ?? '',
  );
}

@immutable
class ProjectTemplate {
  const ProjectTemplate({
    required this.id,
    required this.name,
    required this.timeline,
    required this.slots,
    this.description = '',
    this.createdAt,
  });

  final String id;
  final String name;
  final String description;

  /// The structure, with media clips still present but their assets stripped.
  /// Keeping the clips means every effect, transition and keyframe survives.
  final Timeline timeline;

  final List<TemplateSlot> slots;
  final DateTime? createdAt;

  Duration get duration => timeline.duration;
  int get slotCount => slots.length;

  /// Builds a template from a project.
  factory ProjectTemplate.fromProject(
    Project project, {
    required String name,
    String description = '',
  }) {
    final slots = <TemplateSlot>[];
    for (final track in project.timeline.tracks) {
      for (final clip in track.clips) {
        if (clip is! MediaClip) continue;
        slots.add(
          TemplateSlot(
            clipId: clip.id,
            trackId: track.id,
            start: clip.start,
            duration: clip.duration,
            kind: clip.kind,
            label: clip.label ?? '',
          ),
        );
      }
    }

    return ProjectTemplate(
      id: IdGenerator.sortable('tpl'),
      name: name,
      description: description,
      // The timeline is kept as-is; asset ids are meaningless without the
      // project's asset map, and `apply` overwrites them anyway.
      timeline: project.timeline,
      slots: slots,
      createdAt: DateTime.now(),
    );
  }

  /// Fills the template's slots with [assets], in order.
  ///
  /// Each clip is retimed to the slot's length rather than the asset's, which
  /// is what preserves the template's rhythm. An asset shorter than its slot is
  /// the one case that cannot be honoured — the slot shrinks and everything
  /// after it ripples, reported in [TemplateApplication.shortfalls].
  TemplateApplication apply({
    required String projectName,
    required List<MediaAsset> assets,
  }) {
    final shortfalls = <String>[];
    final used = <MediaAsset>[];
    var timeline = this.timeline;

    // Match assets to slots by kind, in order. A smarter matcher (duration,
    // orientation) is possible, but order is what users expect and can predict.
    final pool = List<MediaAsset>.of(assets);

    for (final slot in slots) {
      final index = pool.indexWhere((a) => slot.accepts(a.kind));
      if (index < 0) continue;
      final asset = pool.removeAt(index);
      used.add(asset);

      final found = timeline.findClip(slot.clipId);
      if (found == null) continue;
      final (track, clip) = found;
      if (clip is! MediaClip) continue;

      // Honour the slot's length where the asset allows it.
      var duration = slot.duration;
      if (asset.kind != AssetKind.image && asset.duration < duration) {
        shortfalls.add(
          '"${asset.displayName}" is ${TimeUtils.formatShort(asset.duration)} '
          'but its slot needs ${TimeUtils.formatShort(slot.duration)}',
        );
        duration = asset.duration;
      }

      final Clip filled = switch (clip) {
        VideoClip() => clip.copyWith(
          assetId: asset.id,
          duration: duration,
          sourceIn: Duration.zero,
        ),
        AudioClip() => clip.copyWith(
          assetId: asset.id,
          duration: duration,
          sourceIn: Duration.zero,
        ),
        ImageClip() => clip.copyWith(assetId: asset.id, duration: duration),
      };
      timeline = timeline.replaceTrack(track.replaceClip(filled));
    }

    // Any slot left unfilled would render as a missing-media hole, so drop it
    // and close the gap rather than exporting a black stretch.
    final filledIds = <String>{};
    for (var i = 0; i < used.length && i < slots.length; i++) {
      filledIds.add(slots[i].clipId);
    }
    for (final slot in slots) {
      if (filledIds.contains(slot.clipId)) continue;
      final found = timeline.findClip(slot.clipId);
      if (found == null) continue;
      timeline = timeline.replaceTrack(found.$1.removeClip(slot.clipId));
    }

    final now = DateTime.now();
    return TemplateApplication(
      project: Project(
        id: IdGenerator.project(),
        name: projectName,
        timeline: timeline,
        createdAt: now,
        updatedAt: now,
        assets: {for (final a in used) a.id: a},
      ),
      filledSlots: used.length,
      unfilledSlots: slots.length - used.length,
      shortfalls: shortfalls,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'timeline': timeline.toJson(),
    'slots': slots.map((s) => s.toJson()).toList(),
    if (createdAt != null) 'createdAt': createdAt!.millisecondsSinceEpoch,
  };

  factory ProjectTemplate.fromJson(Map<String, dynamic> json) => ProjectTemplate(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Template',
    description: json['description'] as String? ?? '',
    timeline: Timeline.fromJson(
      ((json['timeline'] as Map?) ?? const {}).cast<String, dynamic>(),
    ),
    slots: ((json['slots'] as List?) ?? const [])
        .map((e) => TemplateSlot.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
  );
}

@immutable
class TemplateApplication {
  const TemplateApplication({
    required this.project,
    required this.filledSlots,
    required this.unfilledSlots,
    required this.shortfalls,
  });

  final Project project;
  final int filledSlots;
  final int unfilledSlots;

  /// Slots whose media was too short — the template's timing could not be
  /// honoured exactly. Reported rather than silently absorbed.
  final List<String> shortfalls;

  bool get isComplete => unfilledSlots == 0 && shortfalls.isEmpty;
}
