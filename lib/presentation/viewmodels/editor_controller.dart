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
import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/debouncer.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/ducking.dart';
import '../../domain/entities/effect.dart';
import '../../domain/entities/keyframe.dart';
import '../../domain/entities/marker.dart';
import '../../domain/entities/mask.dart';
import '../../domain/entities/media_asset.dart';
import '../../domain/entities/subtitle.dart';
import '../../domain/entities/text_style_spec.dart';
import '../../domain/entities/timeline.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/transform2d.dart';
import '../../domain/entities/transition.dart';
import '../../domain/entities/voice_effect.dart';
import '../../domain/repositories/ai_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/repositories/project_repository.dart';
import '../../domain/usecases/timeline_operations.dart';
import '../../engine/audio/silence_detector.dart';
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
          selectedClipIds: current.selectedClipIds,
        ),
      ],
      selectedClipIds: entry.selectedClipIds,
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
          selectedClipIds: current.selectedClipIds,
        ),
      ],
      selectedClipIds: entry.selectedClipIds,
      isDirty: true,
      clearMessages: true,
    );
    ref.read(playheadControllerProvider.notifier).setDuration(entry.timeline.duration);
    _scheduleSave();
  }

  /// Steps the edit state [steps] entries back (positive) or forward
  /// (negative) through history in one gesture.
  ///
  /// Implemented as repeated undo/redo rather than a direct jump so the
  /// stacks stay exactly as if the user had tapped the buttons that many
  /// times — including being able to change their mind and come back.
  void jumpHistory(int steps) {
    if (steps > 0) {
      for (var i = 0; i < steps && (state?.canUndo ?? false); i++) {
        undo();
      }
    } else {
      for (var i = 0; i < -steps && (state?.canRedo ?? false); i++) {
        redo();
      }
    }
  }

  // ── Selection ────────────────────────────────────────────────────────

  /// Replaces the selection. Pass null to clear.
  void select(String? clipId, {String? trackId}) {
    final current = state;
    if (current == null) return;
    state = clipId == null
        ? current.copyWith(clearSelection: true)
        : current.copyWith(
            selectedClipIds: {clipId},
            selectedTrackId: trackId,
          );
  }

  /// Adds or removes one clip from the selection — the long-press / modifier
  /// gesture.
  void toggleSelection(String clipId, {String? trackId}) {
    final current = state;
    if (current == null) return;

    final next = Set<String>.of(current.selectedClipIds);
    if (!next.remove(clipId)) next.add(clipId);

    state = next.isEmpty
        ? current.copyWith(clearSelection: true)
        : current.copyWith(selectedClipIds: next, selectedTrackId: trackId);
  }

  /// Selects every clip on a track, or the whole timeline when [trackId] is
  /// null.
  void selectAll({String? trackId}) {
    final current = state;
    if (current == null) return;

    final ids = <String>{};
    for (final track in current.timeline.tracks) {
      if (trackId != null && track.id != trackId) continue;
      for (final clip in track.clips) {
        ids.add(clip.id);
      }
    }
    if (ids.isEmpty) return;
    state = current.copyWith(selectedClipIds: ids, selectedTrackId: trackId);
  }

  // ── Clipboard ────────────────────────────────────────────────────────

  void copySelection() {
    final current = state;
    if (current == null || !current.hasSelection) return;

    final clips = current.selectedClips;
    if (clips.isEmpty) return;

    state = current.copyWith(
      clipboard: clips,
      statusMessage: '${clips.length} clip(s) copied',
    );
  }

  void cutSelection() {
    final current = state;
    if (current == null || !current.hasSelection) return;

    final clips = current.selectedClips;
    if (clips.isEmpty) return;

    final result = TimelineOperations.deleteMany(
      current.timeline,
      current.selectedClipIds,
    );
    _apply(result, 'cut');
    state = state?.copyWith(clipboard: clips, clearSelection: true);
  }

  /// Pastes at the playhead, preserving the relative spacing of the copy.
  void paste() {
    final current = state;
    if (current == null || !current.canPaste) return;

    final at = ref.read(playheadControllerProvider).position;
    _apply(
      TimelineOperations.paste(current.timeline, current.clipboard, at),
      'paste',
    );
  }

  // ── Markers ──────────────────────────────────────────────────────────

  void addMarkerAtPlayhead({String label = '', MarkerKind kind = MarkerKind.note}) {
    final current = state;
    if (current == null) return;
    final at = ref.read(playheadControllerProvider).position;
    _apply(
      TimelineOperations.addMarker(
        current.timeline,
        at,
        label: label,
        kind: kind,
      ),
      'add marker',
    );
  }

  void removeMarker(String markerId) {
    final current = state;
    if (current == null) return;
    _apply(
      TimelineOperations.removeMarker(current.timeline, markerId),
      'remove marker',
    );
  }

  void renameMarker(String markerId, String label) {
    final current = state;
    if (current == null) return;
    _apply(
      TimelineOperations.renameMarker(current.timeline, markerId, label),
      'rename marker',
    );
  }

  /// Detects beats on the selected audio clip and drops a marker on each.
  Future<void> markBeats() async {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final found = current.timeline.findClip(clipId);
    final clip = found?.$2;
    if (clip is! MediaClip) return;
    final asset = current.project.asset(clip.assetId);
    if (asset == null) return;

    state = current.copyWith(isBusy: true, busyMessage: 'Finding the beat');
    final result = await _media.detectBeats(asset);

    final latest = state;
    if (latest == null) return;

    result.fold(
      (beats) {
        // Beats come back in source time; shift them onto the clip's position.
        final onTimeline = beats
            .map((b) => clip.start + b)
            .where((t) => t >= clip.start && t < clip.end)
            .toList();
        state = latest.copyWith(isBusy: false);
        _apply(
          TimelineOperations.setBeatMarkers(latest.timeline, onTimeline),
          'mark beats',
        );
        state = state?.copyWith(
          statusMessage: '${onTimeline.length} beat markers added',
        );
      },
      (failure) => state = latest.copyWith(
        isBusy: false,
        errorMessage: failure.message,
      ),
    );
  }

  // ── Masking ──────────────────────────────────────────────────────────

  void setMask(Mask mask) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.setMask(timeline, clipId, mask),
    'mask',
  );

  // ── Speed ramping ────────────────────────────────────────────────────

  /// Installs a speed ramp built from control points, as `(fraction, rate)`.
  void setSpeedRamp(List<(double, double)> points) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return;

    final found = current.timeline.findClip(clipId);
    final clip = found?.$2;
    if (clip is! MediaClip) return;

    if (points.isEmpty) {
      _apply(
        TimelineOperations.setSpeedCurve(current.timeline, clipId, null),
        'clear ramp',
      );
      return;
    }

    var curve = const AnimatableDouble(1.0);
    for (final (fraction, rate) in points) {
      curve = curve.withKeyframe(
        Keyframe(
          time: Duration(
            microseconds:
                (clip.duration.inMicroseconds * fraction.clamp(0.0, 1.0)).round(),
          ),
          value: rate,
        ),
      );
    }

    _apply(
      TimelineOperations.setSpeedCurve(current.timeline, clipId, curve),
      'speed ramp',
    );
  }

  // ── Motion tracking ──────────────────────────────────────────────────

  /// Attaches the selected clip to a tracked path, by converting the tracked
  /// points into position keyframes.
  ///
  /// This is exactly what the keyframe model exists for — tracking output is
  /// just an animation curve someone else computed.
  void applyTracking(TrackingResult tracking, {String? clipId}) {
    final current = state;
    final target = clipId ?? current?.selectedClipId;
    if (current == null || target == null || tracking.isEmpty) return;

    final found = current.timeline.findClip(target);
    if (found == null) return;
    final clip = found.$2;

    var x = const AnimatableDouble(0);
    var y = const AnimatableDouble(0);

    for (final point in tracking.points) {
      final local = point.time;
      if (local < Duration.zero || local > clip.duration) continue;
      // Tracker reports 0..1 of the frame; the transform works in offsets from
      // centre, so recentre here rather than making every consumer do it.
      x = x.withKeyframe(
        Keyframe(time: local, value: point.x - 0.5, easing: Easing.linear),
      );
      y = y.withKeyframe(
        Keyframe(time: local, value: point.y - 0.5, easing: Easing.linear),
      );
    }

    if (x.keyframes.isEmpty) {
      state = current.copyWith(
        errorMessage: 'The tracked path does not overlap this clip.',
      );
      return;
    }

    final updated = clip.copyWithBase(
      transform: clip.transform.copyWith(x: x, y: y),
    );
    _apply(
      Result.ok(current.timeline.replaceTrack(found.$1.replaceClip(updated))),
      'attach to track',
    );
    state = state?.copyWith(
      statusMessage: '${x.keyframes.length} tracking keyframes applied',
    );
  }

  // ── Auto-reframe ─────────────────────────────────────────────────────

  /// Converts the project to a new aspect ratio, keyframing each clip's
  /// position to keep [focus] centred.
  ///
  /// With no tracking data every clip is simply centred, which is still better
  /// than the letterboxing a bare canvas change would give.
  void autoReframe(
    AspectPreset preset, {
    Map<String, TrackingResult> focus = const {},
  }) {
    final current = state;
    if (current == null) return;

    var timeline = current.timeline.copyWith(
      width: preset.width,
      height: preset.height,
      aspectPreset: preset,
    );

    for (final track in timeline.tracks) {
      if (!track.type.isVisual) continue;

      final reframed = <Clip>[];
      for (final clip in track.clips) {
        final path = focus[clip.id];
        if (path == null || path.isEmpty) {
          // No subject to follow: centre it and let the fit handle the rest.
          reframed.add(
            clip.copyWithBase(
              transform: clip.transform.copyWith(
                x: const AnimatableDouble.constant(0),
                y: const AnimatableDouble.constant(0),
              ),
            ),
          );
          continue;
        }

        var x = const AnimatableDouble(0);
        var y = const AnimatableDouble(0);
        for (final point in path.points) {
          if (point.time < Duration.zero || point.time > clip.duration) continue;
          // Move the frame *opposite* the subject so the subject lands centre.
          x = x.withKeyframe(
            Keyframe(time: point.time, value: 0.5 - point.x, easing: Easing.linear),
          );
          y = y.withKeyframe(
            Keyframe(time: point.time, value: 0.5 - point.y, easing: Easing.linear),
          );
        }

        reframed.add(
          clip.copyWithBase(
            transform: clip.transform.copyWith(x: x, y: y),
          ),
        );
      }
      timeline = timeline.replaceTrack(track.withClips(reframed));
    }

    _apply(Result.ok(timeline), 'auto-reframe');
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

  /// Applies [operation] to every selected clip, in one undo step.
  ///
  /// Multi-select is not decoration: if three clips are selected, a speed
  /// change must hit all three. Folding here means each command stays a single
  /// line and cannot forget the rest of the selection.
  ///
  /// A clip the operation rejects (locked, wrong kind) is skipped rather than
  /// aborting the batch — selecting a mixed bag and speeding up "the video
  /// ones" is a reasonable thing to do.
  void _applyToSelection(
    Result<Timeline> Function(Timeline timeline, String clipId) operation,
    String label, {
    String? emptyMessage,
  }) {
    final current = state;
    if (current == null || !current.hasSelection) return;

    var timeline = current.timeline;
    var applied = 0;
    Failure? lastFailure;

    for (final clipId in current.selectedClipIds) {
      final result = operation(timeline, clipId);
      result.fold(
        (next) {
          timeline = next;
          applied++;
        },
        (failure) => lastFailure = failure,
      );
    }

    if (applied == 0) {
      state = current.copyWith(
        errorMessage:
            emptyMessage ?? lastFailure?.message ?? 'That does not apply here.',
      );
      return;
    }

    _apply(
      Result.ok(timeline),
      applied > 1 ? '$label ($applied clips)' : label,
    );
  }

  // ── Structural edits ─────────────────────────────────────────────────

  void splitAtPlayhead() {
    final current = state;
    if (current == null) return;

    final playhead = ref.read(playheadControllerProvider).position;

    // With nothing selected, split whatever is under the playhead on the
    // topmost visual track — the thing the user is looking at.
    if (!current.hasSelection) {
      final under = _clipUnderPlayhead(current.timeline, playhead)?.id;
      if (under == null) {
        state =
            current.copyWith(errorMessage: 'Nothing to split at the playhead.');
        return;
      }
      _apply(
        TimelineOperations.split(current.timeline, under, playhead),
        'split',
      );
      return;
    }

    // Selected clips that the playhead does not cross are simply not split;
    // this is the razor-across-the-selection behaviour an editor expects.
    _applyToSelection(
      (timeline, clipId) => TimelineOperations.split(timeline, clipId, playhead),
      'split',
      emptyMessage: 'The playhead is not over any selected clip.',
    );
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
    if (current == null || !current.hasSelection) return;
    _apply(
      TimelineOperations.deleteMany(
        current.timeline,
        current.selectedClipIds,
        ripple: ripple,
      ),
      current.hasMultipleSelected
          ? 'delete ${current.selectedClipIds.length} clips'
          : 'delete',
    );
    state = state?.copyWith(clearSelection: true);
  }

  void duplicateSelected() => _applyToSelection(
    TimelineOperations.duplicate,
    'duplicate',
  );

  void setSpeed(double speed) => _applyToSelection(
    (timeline, clipId) =>
        TimelineOperations.setSpeed(timeline, clipId, speed),
    'speed',
  );

  void reverseSelected() =>
      _applyToSelection(TimelineOperations.reverse, 'reverse');

  void freezeFrameAtPlayhead({
    Duration hold = const Duration(seconds: 2),
  }) {
    final playhead = ref.read(playheadControllerProvider).position;
    _applyToSelection(
      (timeline, clipId) => TimelineOperations.freezeFrame(
        timeline,
        clipId,
        playhead,
        holdDuration: hold,
      ),
      'freeze frame',
    );
  }

  void rotateSelected({int quarterTurns = 1}) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.rotate(
      timeline,
      clipId,
      quarterTurns: quarterTurns,
    ),
    'rotate',
  );

  void flipSelected({required bool horizontal}) => _applyToSelection(
    (timeline, clipId) => horizontal
        ? TimelineOperations.flipHorizontal(timeline, clipId)
        : TimelineOperations.flipVertical(timeline, clipId),
    'flip',
  );

  void cropSelected(CropRect crop) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.crop(timeline, clipId, crop),
    'crop',
  );

  void setOpacity(double opacity) => _applyToSelection(
    (timeline, clipId) =>
        TimelineOperations.setOpacity(timeline, clipId, opacity),
    'opacity',
  );

  // ── Three-point trims ────────────────────────────────────────────────

  /// Slides the source window without moving the clip.
  ///
  /// The asset's full length is passed in so the window cannot run past the
  /// end of the take — the timeline does not know how long the file is.
  void slipSelected(Duration by) {
    final current = state;
    if (current == null) return;

    _applyToSelection(
      (timeline, clipId) {
        final clip = timeline.findClip(clipId)?.$2;
        final limit = clip is MediaClip
            ? current.project.asset(clip.assetId)?.duration
            : null;
        return TimelineOperations.slip(
          timeline,
          clipId,
          by,
          sourceLimit: limit,
        );
      },
      'slip',
    );
  }

  /// Moves the clip and lets its neighbours absorb the difference.
  void slideSelected(Duration by) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.slide(timeline, clipId, by),
    'slide',
  );

  /// Moves one cut, trading length between the two clips that share it.
  void rollSelected(Duration by, {bool atStart = false}) => _applyToSelection(
    (timeline, clipId) =>
        TimelineOperations.roll(timeline, clipId, by, atStart: atStart),
    'roll',
  );

  // ── Beat-synced cutting ──────────────────────────────────────────────

  /// Razors the selection at every beat marker, in one undo step.
  ///
  /// With nothing selected it cuts everything the beats cross, which is the
  /// "chop the whole edit to the music" gesture. Returns how many cuts landed
  /// so the caller can say something truthful instead of a bare "done".
  int cutOnBeats({MarkerKind kind = MarkerKind.beat, int everyNth = 1}) {
    final current = state;
    if (current == null) return 0;

    var beats = current.timeline.markers
        .where((m) => m.kind == kind)
        .map((m) => m.time)
        .toList()
      ..sort();

    if (beats.isEmpty) {
      state = current.copyWith(
        errorMessage: 'Detect beats first — there are no beat markers.',
      );
      return 0;
    }

    // Cutting on every beat of a 120 BPM track gives a cut twice a second,
    // which is rarely what anyone wants; taking every nth beat is how the bar
    // gets picked out.
    if (everyNth > 1) {
      beats = [
        for (var i = 0; i < beats.length; i += everyNth) beats[i],
      ];
    }

    final before = current.timeline.clipCount;
    _applyWholeTimeline(
      (timeline) => TimelineOperations.razor(
        timeline,
        beats,
        clipIds: current.hasSelection ? current.selectedClipIds : null,
      ),
      'cut on beats',
    );
    return (state?.timeline.clipCount ?? before) - before;
  }

  /// Applies a whole-timeline operation with the standard history handling.
  void _applyWholeTimeline(
    Result<Timeline> Function(Timeline timeline) operation,
    String label,
  ) {
    final current = state;
    if (current == null) return;
    _apply(operation(current.timeline), label);
  }

  /// Crossfades the selected audio clip into the next one.
  void setAudioCrossfade(Duration duration) => _applyToSelection(
    (timeline, clipId) =>
        TimelineOperations.setAudioCrossfade(timeline, clipId, duration),
    'crossfade',
  );

  // ── Audio character ──────────────────────────────────────────────────

  void setPitch(double semitones) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.updateAudioCharacter(
      timeline,
      clipId,
      pitchSemitones: semitones,
    ),
    'pitch',
  );

  void setPreservePitch({required bool preserve}) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.updateAudioCharacter(
      timeline,
      clipId,
      preservePitch: preserve,
    ),
    preserve ? 'keep pitch' : 'tape-style pitch',
  );

  void setVoiceEffect(VoiceEffect effect) => _applyToSelection(
    (timeline, clipId) => TimelineOperations.updateAudioCharacter(
      timeline,
      clipId,
      voiceEffect: effect,
    ),
    effect.isActive ? effect.label.toLowerCase() : 'clear voice effect',
  );

  // ── Voiceover ────────────────────────────────────────────────────────

  /// Speaks [text] through the AI server and drops the result on an audio
  /// track at the playhead. Returns an error message, or null on success.
  Future<String?> addTtsVoiceover(
    String text, {
    String voice = 'alloy',
    void Function(double progress)? onProgress,
  }) async {
    final current = state;
    if (current == null) return 'No project open.';

    final synth = await ref
        .read(aiRepositoryProvider)
        .synthesizeSpeech(text, voice: voice, onProgress: onProgress);
    final path = synth.valueOrNull;
    if (path == null) return synth.failureOrNull?.message ?? 'Voiceover failed.';

    final imported = await _media.importFile(path);
    final asset = imported.valueOrNull;
    if (asset == null) {
      return imported.failureOrNull?.message ?? 'Could not import the audio.';
    }

    final refreshed = state;
    if (refreshed == null) return 'The project closed mid-flight.';

    var timeline = refreshed.timeline;
    var track = _firstTrackOfType(timeline, TrackType.audio);
    if (track == null) {
      timeline = TimelineOperations.addTrack(timeline, TrackType.audio)
          .getOrElse(timeline);
      track = timeline.tracks.last;
    }

    final at = ref.read(playheadControllerProvider).position;
    final result = TimelineOperations.insertClip(
      timeline,
      track.id,
      AudioClip(
        id: IdGenerator.clip(),
        trackId: track.id,
        start: at,
        duration: asset.duration,
        assetId: asset.id,
        label: 'Voiceover',
        isVoiceOver: true,
      ),
      at: at,
    );

    state = refreshed.copyWith(
      project: refreshed.project.withAsset(asset),
    );
    _apply(result, 'voiceover');
    return null;
  }

  // ── Versions ─────────────────────────────────────────────────────────

  /// Snapshots available for this project, newest first.
  Future<List<DateTime>> listVersions() async {
    final result = await _projects.listBackups(projectId);
    return result.getOrElse(const []);
  }

  /// Replaces the current project with a stored snapshot.
  ///
  /// The current state is saved first, so the state being abandoned becomes
  /// the newest backup — restoring is never a one-way door.
  Future<bool> restoreVersion(int index) async {
    await flush();
    final result = await _projects.restoreBackup(projectId, index);
    return result.fold(
      (project) {
        state = EditorState(project: project);
        ref.read(playheadControllerProvider.notifier)
          ..setDuration(project.duration)
          ..seek(Duration.zero);
        _log.i('version restored', fields: {'index': index});
        return true;
      },
      (failure) {
        state = state?.copyWith(errorMessage: failure.message);
        return false;
      },
    );
  }

  // ── Grouping ─────────────────────────────────────────────────────────

  /// Groups the selection, or dissolves it when exactly one group is
  /// selected — one button, both directions, no mode.
  void toggleGroup() {
    final current = state;
    if (current == null || !current.hasSelection) return;

    final selected = current.selectedClips;
    if (selected.length == 1 && selected.single is CompoundClip) {
      _apply(
        TimelineOperations.ungroup(current.timeline, selected.single.id),
        'ungroup',
      );
      return;
    }
    _apply(
      TimelineOperations.group(current.timeline, current.selectedClipIds),
      'group ${current.selectedClipIds.length} clips',
    );
  }

  // ── Silence removal ──────────────────────────────────────────────────

  /// Detects silences in the selected clip's audio, without cutting anything.
  ///
  /// Returns the spans in *source* time so the sheet can show them and then
  /// hand the approved list to [removeSilences]. Detection and application
  /// are separate on purpose: an auto-cutter you cannot preview is an
  /// auto-cutter you cannot trust.
  Future<List<SilenceSpan>> detectSilences({
    double threshold = 0.12,
    Duration minSilence = const Duration(milliseconds: 450),
  }) async {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null) return const [];

    final clip = current.timeline.findClip(clipId)?.$2;
    if (clip is! MediaClip) return const [];
    final asset = current.project.asset(clip.assetId);
    if (asset == null || !asset.hasAudioStream) return const [];

    final peaks = await _media.waveform(asset);
    return peaks.fold(
      (data) => SilenceDetector.detect(
        data,
        threshold: threshold,
        minSilence: minSilence,
      ),
      (failure) {
        state = state?.copyWith(errorMessage: failure.message);
        return const [];
      },
    );
  }

  /// Cuts the given silences out of the selected clip in one undo step.
  void removeSilences(List<SilenceSpan> spans) {
    final current = state;
    final clipId = current?.selectedClipId;
    if (current == null || clipId == null || spans.isEmpty) return;

    _apply(
      TimelineOperations.removeSilences(
        current.timeline,
        clipId,
        [for (final s in spans) (start: s.start, end: s.end)],
      ),
      'remove ${spans.length} silence(s)',
    );
  }

  // ── Ken Burns ────────────────────────────────────────────────────────

  /// Adds a slow camera move to the selected stills.
  void applyKenBurns({
    KenBurnsMove move = KenBurnsMove.zoomIn,
    double zoom = 0.18,
  }) => _applyToSelection(
    (timeline, clipId) =>
        TimelineOperations.kenBurns(timeline, clipId, move: move, zoom: zoom),
    move.label.toLowerCase(),
  );

  /// Removes every transform keyframe from the selection.
  void clearMotion() =>
      _applyToSelection(TimelineOperations.clearMotion, 'clear motion');

  // ── Keyframes ────────────────────────────────────────────────────────

  void setKeyframeAtPlayhead(TransformChannel channel, double value) {
    final playhead = ref.read(playheadControllerProvider).position;
    _applyToSelection(
      (timeline, clipId) {
        final found = timeline.findClip(clipId);
        if (found == null) return Result.err(const InvalidEditFailure('clip not found'));

        // The keyframe lives in clip-local time, so a clip the playhead is
        // not over has no valid position for one.
        final local = found.$2.localTime(playhead);
        if (local < Duration.zero || local > found.$2.duration) {
          return Result.err(
            const InvalidEditFailure('the playhead is outside the clip'),
          );
        }
        return TimelineOperations.setTransformKeyframe(
          timeline,
          clipId,
          channel,
          local,
          value,
        );
      },
      'keyframe',
      emptyMessage: 'Move the playhead over the clip to add a keyframe.',
    );
  }

  void removeKeyframeAtPlayhead(TransformChannel channel) {
    final playhead = ref.read(playheadControllerProvider).position;
    _applyToSelection(
      (timeline, clipId) {
        final found = timeline.findClip(clipId);
        if (found == null) return Result.err(const InvalidEditFailure('clip not found'));
        return TimelineOperations.removeTransformKeyframe(
          timeline,
          clipId,
          channel,
          found.$2.localTime(playhead),
        );
      },
      'remove keyframe',
    );
  }

  // ── Effects & transitions ────────────────────────────────────────────

  void addEffect(EffectType type) {
    final spec = EffectCatalog.specFor(type);
    if (spec == null) return;
    // A fresh instance per clip: sharing one would make them share an id, and
    // editing one would silently edit them all.
    _applyToSelection(
      (timeline, clipId) => TimelineOperations.addEffect(
        timeline,
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
    state = state?.copyWith(
      selectedClipIds: {clip.id},
      selectedTrackId: track.id,
    );
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
    bool karaoke = false,
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
          // Word clocks arrive in source time; the clip wants them local.
          wordTimings: karaoke
              ? [for (final w in cue.words) w.shifted(-cue.start)]
              : const [],
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

  void toggleTrackSolo(String trackId) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;
    _apply(
      Result.ok(
        current.timeline.replaceTrack(track.copyWith(solo: !track.solo)),
      ),
      track.solo ? 'unsolo track' : 'solo track',
    );
  }

  void setTrackVolume(String trackId, double volume) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;
    _apply(
      Result.ok(
        current.timeline.replaceTrack(
          track.copyWith(volume: volume.clamp(0.0, 2.0)),
        ),
      ),
      'track volume',
    );
  }

  /// Sets or clears automatic ducking on a track. Pass null to turn it off.
  void setTrackDucking(String trackId, Ducking? ducking) {
    final current = state;
    final track = current?.timeline.trackById(trackId);
    if (current == null || track == null) return;

    if (ducking != null && ducking.keyTrackId == trackId) {
      state = current.copyWith(
        errorMessage: 'A track cannot duck under itself.',
      );
      return;
    }

    _apply(
      Result.ok(
        current.timeline.replaceTrack(
          ducking == null
              ? track.copyWith(clearDucking: true)
              : track.copyWith(ducking: ducking),
        ),
      ),
      ducking == null ? 'stop ducking' : 'duck track',
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
