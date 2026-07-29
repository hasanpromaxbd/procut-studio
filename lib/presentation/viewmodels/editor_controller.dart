/// The editor's command surface.
///
/// Every user action funnels through here, and every timeline mutation goes
/// through [TimelineOperations], which is pure. That split means this class
/// only handles orchestration — history, auto-save, error surfacing — and the
/// editing rules stay testable without a widget tree.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/di/providers.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/debouncer.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/keyframe.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/subtitle.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/transform2d.dart';
import '../../domain/entities/transition.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/repositories/project_repository.dart';
import '../../domain/usecases/timeline_operations.dart';
import '../../engine/effects/effect_catalog.dart';
import 'editor_state.dart';
import 'playhead_controller.dart';

/// Family key: which project the editor is open on.
final editorControllerProvider =
    NotifierProvider.family<EditorController, EditorState?, String>(
      EditorController.new,
    );

class EditorController extends Notifier<EditorState?> {
  /// In Riverpod 3 a family notifier receives its argument through the
  /// constructor rather than through `build(arg)`.
  EditorController(this.projectId);

  final String projectId;

  static const _log = Log('EditorController');

  late final Debouncer _autoSave = Debouncer(AppConstants.autoSaveDebounce);
  Timer? _periodicSave;

  ProjectRepository get _projects => ref.read(projectRepositoryProvider);
  MediaRepository get _media => ref.read(mediaRepositoryProvider);

  @override
  EditorState? build() {
    ref.onDispose(() {
      _autoSave.dispose();
      _periodicSave?.cancel();
    });
    unawaited(_load(projectId));
    return null;
  }

  Future<void> _load(String projectId) async {
    final result = await _projects.load(projectId);
    result.fold(
      (project) {
        state = EditorState(project: project);
        ref.read(playheadControllerProvider.notifier)
          ..setDuration(project.duration)
          ..seek(project.lastPlayhead);
        unawaited(_projects.markOpened(projectId));
        _startPeriodicSave();
        _log.i('opened', fields: {'id': projectId, 'clips': project.clipCount});
      },
      (failure) {
        _log.e('open failed: ${failure.message}');
        state = null;
      },
    );
  }

  void _startPeriodicSave() {
    _periodicSave?.cancel();
    // A belt-and-braces save on top of the debounced one: a user who edits
    // continuously for a minute never triggers the debounce trailing edge.
    _periodicSave = Timer.periodic(AppConstants.autoSaveInterval, (_) {
      if (state?.isDirty ?? false) unawaited(save());
    });
  }

  // ── History ──────────────────────────────────────────────────────────

  void _apply(Result<Timeline> result, String label) {
    final current = state;
    if (current == null) return;

    result.fold(
      (timeline) {
        state = current.withEdit(timeline, label);
        ref.read(playheadControllerProvider.notifier).setDuration(timeline.duration);
        _scheduleSave();
      },
      (failure) {
        // An invalid edit is normal user behaviour (dragging a clip onto
        // another), not an error worth a dialog — a quiet banner is enough.
        state = current.copyWith(errorMessage: failure.message);
        _log.d('edit rejected: ${failure.message}');
      },
    );
  }

  void undo() {
    final current = state;
    if (current == null || !current.canUndo) return;

    final entry = current.undoStack.last;
    state = current.copyWith(
      project: current.project.withTimeline(entry.timeline),
      undoStack: current.undoStack.sublist(0, current.undoStack.length - 1),
      redoStack: [
        ...current.redoStack,
        UndoEntry(
          timeline: current.timeline,
          label: entry.label,
          selectedClipId: current.selectedClipId,
        ),
      ],
      selectedClipId: entry.selectedClipId,
      isDirty: true,
      clearMessages: true,
    );
    ref.read(playheadControllerProvider.notifier).setDuration(entry.timeline.duration);
    _scheduleSave();
  }

  void redo() {
    final current = state;
    if (current == null || !current.canRedo) return;

    final entry = current.redoStack.last;
    state = current.copyWith(
      project: current.project.withTimeline(entry.timeline),
      redoStack: current.redoStack.sublist(0, current.redoStack.length - 1),
      undoStack: [
        ...current.undoStack,
        UndoEntry(
          timeline: current.timeline,
          label: entry.label,
          selectedClipId: current.selectedClipId,
        ),
      ],
      selectedClipId: entry.selectedClipId,
      isDirty: true,
      clearMessages: true,
    );
    ref.read(playheadControllerProvider.notifier).setDuration(entry.timeline.duration);
    _scheduleSave();
  }

  // ── Selection ────────────────────────────────────────────────────────

  void select(String? clipId, {String? trackId}) {
    final current = state;
    if (current == null) return;
    state = clipId == null
        ? current.copyWith(clearSelection: true)
        : current.copyWith(selectedClipId: clipId, selectedTrackId: trackId);
  }

  void setTool(EditorTool tool) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(activeTool: tool);
  }

  void clearMessages() {
    final current = state;
    if (current == null) return;
    state = current.copyWith(clearMessages: true);
  }

  // ── Structural edits ─────────────────────────────────────────────────

  void splitAtPlayhead() {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null) return;

    final playhead = ref.read(playheadControllerProvider).position;

    // With nothing selected, split whatever is under the playhead on the
    // topmost visual track — the thing the user is looking at.
    final target = clipId ?? _clipUnderPlayhead(current.timeline, playhead)?.id;
    if (target == null) {
      state = current.copyWith(errorMessage: 'Nothing to split at the playhead.');
      return;
    }
    _apply(TimelineOperations.split(current.timeline, target, playhead), 'split');
  }

  Clip? _clipUnderPlayhead(Timeline timeline, Duration playhead) {
    for (final track in timeline.visualTracks.reversed) {
      final clip = track.clipAt(playhead);
      if (clip != null) return clip;
    }
    for (final track in timeline.tracks) {
      final clip = track.clipAt(playhead);
      if (clip != null) return clip;
    }
    return null;
  }

  void trimStart(String clipId, Duration newStart) {
    final current = state;
    if (current == null) return;
    _apply(
      TimelineOperations.trimStart(current.timeline, clipId, newStart),
      'trim',
    );
  }

  void trimEnd(String clipId, Duration newEnd) {
    final current = state;
    if (current == null) return;

    // Pass the source length so the clip cannot be dragged past the end of its
    // media — the operation cannot know this, only the project can.
    final found = current.timeline.findClip(clipId);
    final clip = found?.$2;
    final limit = clip is MediaClip
        ? current.project.asset(clip.assetId)?.duration
        : null;

    _apply(
      TimelineOperations.trimEnd(
        current.timeline,
        clipId,
        newEnd,
        sourceLimit: limit,
      ),
      'trim',
    );
  }

  void moveClip(String clipId, Duration newStart, {String? targetTrackId}) {
    final current = state;
    if (current == null) return;
    _apply(
      TimelineOperations.move(
        current.timeline,
        clipId,
        newStart,
        targetTrackId: targetTrackId,
      ),
      'move',
    );
  }

  /// Streams a drag without pushing an undo entry per frame.
  void moveClipLive(String clipId, Duration newStart, {String? targetTrackId}) {
    final current = state;
    if (current == null) return;
    final result = TimelineOperations.move(
      current.timeline,
      clipId,
      newStart,
      targetTrackId: targetTrackId,
    );
    final timeline = result.valueOrNull;
    if (timeline != null) state = current.withLiveEdit(timeline);
  }

  /// Call when a drag begins so exactly one undo entry covers the gesture.
  void beginGesture(String label) {
    final current = state;
    if (current == null) return;
    state = current.withEdit(current.timeline, label);
  }

  void deleteSelected({bool ripple = false}) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.delete(current.timeline, clipId, ripple: ripple),
      'delete',
    );
    state = state?.copyWith(clearSelection: true);
  }

  void duplicateSelected() {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(TimelineOperations.duplicate(current.timeline, clipId), 'duplicate');
  }

  void setSpeed(double speed) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.setSpeed(current.timeline, clipId, speed),
      'speed',
    );
  }

  void reverseSelected() {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(TimelineOperations.reverse(current.timeline, clipId), 'reverse');
  }

  void freezeFrameAtPlayhead({
    Duration hold = const Duration(seconds: 2),
  }) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    final playhead = ref.read(playheadControllerProvider).position;
    _apply(
      TimelineOperations.freezeFrame(
        current.timeline,
        clipId,
        playhead,
        holdDuration: hold,
      ),
      'freeze frame',
    );
  }

  void rotateSelected({int quarterTurns = 1}) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.rotate(
        current.timeline,
        clipId,
        quarterTurns: quarterTurns,
      ),
      'rotate',
    );
  }

  void flipSelected({required bool horizontal}) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      horizontal
          ? TimelineOperations.flipHorizontal(current.timeline, clipId)
          : TimelineOperations.flipVertical(current.timeline, clipId),
      'flip',
    );
  }

  void cropSelected(CropRect crop) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(TimelineOperations.crop(current.timeline, clipId, crop), 'crop');
  }

  void setOpacity(double opacity) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.setOpacity(current.timeline, clipId, opacity),
      'opacity',
    );
  }

  // ── Keyframes ────────────────────────────────────────────────────────

  void setKeyframeAtPlayhead(TransformChannel channel, double value) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final found = current.timeline.findClip(clipId);
    if (found == null) return;
    final playhead = ref.read(playheadControllerProvider).position;
    final local = found.$2.localTime(playhead);
    if (local < Duration.zero || local > found.$2.duration) {
      state = current.copyWith(
        errorMessage: 'Move the playhead over the clip to add a keyframe.',
      );
      return;
    }

    _apply(
      TimelineOperations.setTransformKeyframe(
        current.timeline,
        clipId,
        channel,
        local,
        value,
      ),
      'keyframe',
    );
  }

  void removeKeyframeAtPlayhead(TransformChannel channel) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    final found = current.timeline.findClip(clipId);
    if (found == null) return;
    final playhead = ref.read(playheadControllerProvider).position;
    _apply(
      TimelineOperations.removeTransformKeyframe(
        current.timeline,
        clipId,
        channel,
        found.$2.localTime(playhead),
      ),
      'remove keyframe',
    );
  }

  // ── Effects & transitions ────────────────────────────────────────────

  void addEffect(EffectType type) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final spec = EffectCatalog.specFor(type);
    if (spec == null) return;
    _apply(
      TimelineOperations.addEffect(
        current.timeline,
        clipId,
        spec.instantiate(IdGenerator.effect()),
      ),
      'add ${spec.label.toLowerCase()}',
    );
  }

  void updateEffect(Effect effect) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.updateEffect(current.timeline, clipId, effect),
      'adjust effect',
    );
  }

  void removeEffect(String effectId) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;
    _apply(
      TimelineOperations.removeEffect(current.timeline, clipId, effectId),
      'remove effect',
    );
  }

  void setTransition(String clipId, TransitionType type, {Duration? duration}) {
    final current = state;
    if (current == null) return;
    if (type == TransitionType.none) {
      _apply(
        TimelineOperations.removeTransition(current.timeline, clipId),
        'remove transition',
      );
      return;
    }
    _apply(
      TimelineOperations.setTransition(
        current.timeline,
        clipId,
        Transition(
          id: IdGenerator.transition(),
          type: type,
          duration: duration ?? AppConstants.defaultTransitionDuration,
        ),
      ),
      'add transition',
    );
  }

  // ── Insertion ────────────────────────────────────────────────────────

  Future<void> addMedia(List<String> paths, {Duration? at}) async {
    final current = state;
    if (current == null) return;

    state = current.copyWith(isBusy: true, busyMessage: 'Importing media');
    final imported = await _media.importFiles(paths);

    imported.fold(
      (assets) {
        var project = current.project.withAssets(assets);
        var timeline = project.timeline;

        for (final asset in assets) {
          final trackType = asset.kind == AssetKind.audio
              ? TrackType.audio
              : TrackType.video;
          var track = _firstTrackOfType(timeline, trackType);
          if (track == null) {
            final added = TimelineOperations.addTrack(timeline, trackType);
            timeline = added.getOrElse(timeline);
            track = _firstTrackOfType(timeline, trackType);
          }
          if (track == null) continue;

          final clip = _clipForAsset(asset, track.id, track.duration);
          final result = TimelineOperations.insertClip(
            timeline,
            track.id,
            clip,
            at: at,
          );
          timeline = result.getOrElse(timeline);
        }

        project = project.withTimeline(timeline);
        state = current.copyWith(
          project: project,
          isBusy: false,
          isDirty: true,
          undoStack: [
            ...current.undoStack,
            UndoEntry(timeline: current.timeline, label: 'add media'),
          ],
          redoStack: const [],
          statusMessage: '${assets.length} item(s) added',
        );
        ref.read(playheadControllerProvider.notifier).setDuration(timeline.duration);
        _scheduleSave();

        // Heavy sources get a proxy in the background so scrubbing stays
        // responsive; the edit is usable immediately either way.
        for (final asset in assets.where((a) => a.needsProxy)) {
          unawaited(_buildProxy(asset));
        }
      },
      (failure) {
        state = current.copyWith(isBusy: false, errorMessage: failure.message);
      },
    );
  }

  Future<void> _buildProxy(MediaAsset asset) async {
    final result = await _media.generateProxy(asset);
    final updated = result.valueOrNull;
    final current = state;
    if (updated == null || current == null) return;
    state = current.copyWith(project: current.project.withAsset(updated));
    _log.d('proxy ready', fields: {'asset': asset.id});
  }

  Track? _firstTrackOfType(Timeline timeline, TrackType type) {
    for (final track in timeline.tracks) {
      if (track.type == type) return track;
    }
    return null;
  }

  Clip _clipForAsset(MediaAsset asset, String trackId, Duration start) {
    final id = IdGenerator.clip();
    return switch (asset.kind) {
      AssetKind.video => VideoClip(
        id: id,
        trackId: trackId,
        start: start,
        duration: asset.duration,
        assetId: asset.id,
        label: asset.displayName,
      ),
      AssetKind.audio => AudioClip(
        id: id,
        trackId: trackId,
        start: start,
        duration: asset.duration,
        assetId: asset.id,
        label: asset.displayName,
      ),
      AssetKind.image => ImageClip(
        id: id,
        trackId: trackId,
        start: start,
        // A still has no intrinsic length; three seconds is the conventional
        // default and long enough to be trimmed rather than hunted for.
        duration: const Duration(seconds: 3),
        assetId: asset.id,
        label: asset.displayName,
      ),
    };
  }

  void addTextLayer(String text, {TextStyleSpec? style, Duration? at}) {
    final current = state;
    if (current == null) return;

    var timeline = current.timeline;
    var track = _firstTrackOfType(timeline, TrackType.text);
    if (track == null) {
      timeline = TimelineOperations.addTrack(timeline, TrackType.text)
          .getOrElse(timeline);
      track = _firstTrackOfType(timeline, TrackType.text);
    }
    if (track == null) return;

    final start = at ?? ref.read(playheadControllerProvider).position;
    final clip = TextClip(
      id: IdGenerator.textLayer(),
      trackId: track.id,
      start: start,
      duration: const Duration(seconds: 3),
      text: text,
      style: style ?? const TextStyleSpec(),
      animationIn: TextAnimation.fadeIn,
    );

    _apply(
      TimelineOperations.insertClip(timeline, track.id, clip, at: start),
      'add text',
    );
    state = state?.copyWith(selectedClipId: clip.id, selectedTrackId: track.id);
  }

  void updateTextClip(String clipId, {String? text, TextStyleSpec? style,
      TextAnimation? animationIn, TextAnimation? animationOut}) {
    final current = state;
    if (current == null) return;
    final found = current.timeline.findClip(clipId);
    final clip = found?.$2;
    if (clip is! TextClip) return;

    final updated = clip.copyWith(
      text: text,
      style: style,
      animationIn: animationIn,
      animationOut: animationOut,
    );
    final track = found!.$1.replaceClip(updated);
    _apply(Result.ok(current.timeline.replaceTrack(track)), 'edit text');
  }

  /// Turns a recognised [SubtitleTrack] into real text clips.
  ///
  /// Cues land on their own track so the whole caption set can be styled,
  /// moved or deleted as a unit, and each clip is flagged `isSubtitle` so a
  /// later "restyle all captions" acts on exactly these.
  void addSubtitles(
    SubtitleTrack track, {
    TextStyleSpec? style,
    Duration offset = Duration.zero,
  }) {
    final current = state;
    if (current == null || track.isEmpty) return;

    var timeline = current.timeline;
    // A dedicated track, even if a text track already exists: mixing captions
    // in with hand-placed titles makes both harder to manage.
    final added = TimelineOperations.addTrack(timeline, TrackType.text);
    timeline = added.getOrElse(timeline);
    final captionTrack = timeline.tracks.last;

    final captionStyle = style ??
        const TextStyleSpec(
          fontSize: 0.045,
          strokeWidth: 0.08,
          alignment: TextAlignment.center,
        );

    final clips = <Clip>[];
    for (final cue in track.wrapped().cues) {
      final start = cue.start + offset;
      if (cue.duration < AppConstants.minClipDuration) continue;

      clips.add(
        TextClip(
          id: IdGenerator.subtitle(),
          trackId: captionTrack.id,
          start: start,
          duration: cue.duration,
          text: cue.text,
          style: captionStyle,
          isSubtitle: true,
          // Machine transcription is rarely perfect; a low-confidence cue is
          // labelled so the review pass knows where to look.
          label: cue.isUncertain ? 'check' : null,
          transform: Transform2D.identity.copyWith(
            y: const AnimatableDouble.constant(0.34),
          ),
        ),
      );
    }

    if (clips.isEmpty) return;

    _apply(
      Result.ok(timeline.replaceTrack(captionTrack.withClips(clips))),
      'add captions',
    );
    state = state?.copyWith(
      statusMessage: '${clips.length} captions added — check them before export',
    );
  }

  /// Applies AI-suggested colour correction as a real, editable effect rather
  /// than a hidden adjustment, so the user can tune or remove it.
  void applyColorSuggestion(Map<String, double> values) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final spec = EffectCatalog.specFor(EffectType.colorAdjust);
    if (spec == null) return;

    var effect = spec.instantiate(IdGenerator.effect());
    for (final entry in values.entries) {
      effect = effect.withParamValue(entry.key, entry.value);
    }

    _apply(
      TimelineOperations.addEffect(current.timeline, clipId, effect),
      'AI colour',
    );
  }

  /// Cuts the selected clip at each detected scene change.
  ///
  /// Applied back-to-front: splitting shifts nothing on the timeline, but each
  /// split replaces the clip id, so working forwards would lose the target
  /// after the first cut.
  int applySceneCuts(List<Duration> cutTimes) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null || cutTimes.isEmpty) return 0;

    final found = current.timeline.findClip(clipId);
    if (found == null) return 0;
    final clip = found.$2;

    final inside = cutTimes
        .map((t) => clip.start + t)
        .where((t) => t > clip.start && t < clip.end)
        .toList()
      ..sort();
    if (inside.isEmpty) return 0;

    var timeline = current.timeline;
    var applied = 0;
    for (final at in inside.reversed) {
      // Re-find each time: the id of the piece containing `at` changes as the
      // clip is subdivided.
      final target = _clipContaining(timeline, clip.trackId, at);
      if (target == null) continue;
      final result = TimelineOperations.split(timeline, target.id, at);
      if (result.isOk) {
        timeline = result.valueOrNull!;
        applied++;
      }
    }

    if (applied == 0) return 0;
    _apply(Result.ok(timeline), 'scene cuts');
    state = state?.copyWith(
      clearSelection: true,
      statusMessage: '$applied scene cut(s) applied',
    );
    return applied;
  }

  Clip? _clipContaining(Timeline timeline, String trackId, Duration at) {
    final track = timeline.trackById(trackId);
    if (track == null) return null;
    return track.clipAt(at);
  }

  /// Replaces the selected clip's media with a processed file (upscale,
  /// isolated voice), keeping every edit already made to the clip.
  Future<void> replaceSelectedMedia(String newPath) async {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final imported = await _media.importFile(newPath);
    final asset = imported.valueOrNull;
    if (asset == null) {
      state = current.copyWith(
        errorMessage: imported.failureOrNull?.message ?? 'Import failed.',
      );
      return;
    }

    final found = current.timeline.findClip(clipId);
    if (found == null) return;
    final clip = found.$2;

    final Clip? swapped = switch (clip) {
      VideoClip() => clip.copyWith(assetId: asset.id),
      AudioClip() => clip.copyWith(assetId: asset.id),
      ImageClip() => clip.copyWith(assetId: asset.id),
      _ => null,
    };
    if (swapped == null) return;

    state = current.copyWith(project: current.project.withAsset(asset));
    _apply(
      Result.ok(current.timeline.replaceTrack(found.$1.replaceClip(swapped))),
      'replace media',
    );
  }

  void addSticker({String? emoji, String? assetPath, Duration? at}) {
    final current = state;
    if (current == null) return;

    var timeline = current.timeline;
    var track = _firstTrackOfType(timeline, TrackType.sticker);
    if (track == null) {
      timeline = TimelineOperations.addTrack(timeline, TrackType.sticker)
          .getOrElse(timeline);
      track = _firstTrackOfType(timeline, TrackType.sticker);
    }
    if (track == null) return;

    final start = at ?? ref.read(playheadControllerProvider).position;
    final clip = StickerClip(
      id: IdGenerator.sticker(),
      trackId: track.id,
      start: start,
      duration: const Duration(seconds: 3),
      emoji: emoji,
      assetPath: assetPath,
    );
    _apply(
      TimelineOperations.insertClip(timeline, track.id, clip, at: start),
      'add sticker',
    );
  }

  void addTrack(TrackType type) {
    final current = state;
    if (current == null) return;
    _apply(TimelineOperations.addTrack(current.timeline, type), 'add track');
  }

  void removeTrack(String trackId) {
    final current = state;
    if (current == null) return;
    _apply(
      TimelineOperations.removeTrack(current.timeline, trackId),
      'remove track',
    );
  }

  void toggleTrackMute(String trackId) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;
    _apply(
      Result.ok(
        current.timeline.replaceTrack(track.copyWith(muted: !track.muted)),
      ),
      track.muted ? 'unmute track' : 'mute track',
    );
  }

  void toggleTrackVisibility(String trackId) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;
    _apply(
      Result.ok(
        current.timeline.replaceTrack(track.copyWith(hidden: !track.hidden)),
      ),
      track.hidden ? 'show track' : 'hide track',
    );
  }

  void toggleTrackLock(String trackId) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;
    _apply(
      Result.ok(
        current.timeline.replaceTrack(track.copyWith(locked: !track.locked)),
      ),
      track.locked ? 'unlock track' : 'lock track',
    );
  }

  // ── Project ──────────────────────────────────────────────────────────

  void rename(String name) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(
      project: current.project.copyWith(name: name),
      isDirty: true,
    );
    _scheduleSave();
  }

  void setCanvas(AspectPreset preset) {
    final current = state;
    if (current == null) return;
    _apply(
      Result.ok(
        current.timeline.copyWith(
          width: preset.width,
          height: preset.height,
          aspectPreset: preset,
        ),
      ),
      'change canvas',
    );
  }

  void setFps(int fps) {
    final current = state;
    if (current == null) return;
    // Re-snap every edit onto the new frame grid, or the project keeps
    // sub-frame boundaries the exporter would silently round.
    _apply(
      Result.ok(current.timeline.copyWith(fps: fps).snappedToFrameGrid()),
      'change frame rate',
    );
  }

  void _scheduleSave() => _autoSave.run(() => unawaited(save()));

  Future<void> save() async {
    final current = state;
    if (current == null || current.isSaving) return;

    state = current.copyWith(isSaving: true);
    final playhead = ref.read(playheadControllerProvider).position;
    final toSave = current.project.copyWith(
      lastPlayheadUs: playhead.inMicroseconds,
    );

    final result = await _projects.save(toSave);
    final latest = state;
    if (latest == null) return;

    state = result.fold(
      (_) => latest.copyWith(isSaving: false, isDirty: false, project: toSave),
      (failure) => latest.copyWith(
        isSaving: false,
        errorMessage: failure.message,
      ),
    );
  }

  /// Flushes any pending save. Called when the editor is closed or the app is
  /// backgrounded — the debounce timer will not fire once we are gone.
  Future<void> flush() async {
    _autoSave.cancel();
    if (state?.isDirty ?? false) await save();
  }
}
