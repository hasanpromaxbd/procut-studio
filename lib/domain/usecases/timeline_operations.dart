/// Every structural edit the user can make, as pure functions.
///
/// `Timeline in → Result<Timeline> out`. No I/O, no state, no side effects.
/// That is what makes the undo stack trivial (keep the old value) and the
/// behaviour testable without a device — see `test/unit/timeline_operations_test.dart`.
///
/// All of them preserve two invariants:
///   1. clip boundaries land on the project's frame grid;
///   2. clips within a track never overlap.
library;

import '../../core/constants/app_constants.dart';
import '../../core/error/failure.dart';
import '../../core/error/result.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/math_utils.dart';
import '../../core/utils/time_utils.dart';
import '../entities/clip.dart';
import '../entities/effect.dart';
import '../entities/keyframe.dart';
import '../entities/marker.dart';
import '../entities/mask.dart';
import '../entities/timeline.dart';
import '../entities/track.dart';
import '../entities/transform2d.dart';
import '../entities/transition.dart';

abstract final class TimelineOperations {
  // ── Split ────────────────────────────────────────────────────────────

  /// Cuts [clipId] at [at], producing two clips that together occupy exactly
  /// the original span.
  static Result<Timeline> split(
    Timeline timeline,
    String clipId,
    Duration at,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final cut = TimeUtils.snapToFrame(at, timeline.fps);
    if (!clip.containsTime(cut)) {
      return const Result.err(
        InvalidEditFailure('Playhead is not over this clip.'),
      );
    }

    final leftDuration = cut - clip.start;
    final rightDuration = clip.end - cut;
    if (leftDuration < AppConstants.minClipDuration ||
        rightDuration < AppConstants.minClipDuration) {
      return const Result.err(
        InvalidEditFailure('Both halves must be at least one frame long.'),
      );
    }

    final (left, right) = _splitClip(clip, leftDuration, rightDuration);
    final nextTrack = track.withClips([
      ...track.clips.where((c) => c.id != clipId),
      left,
      right,
    ]);
    return Result.ok(timeline.replaceTrack(nextTrack));
  }

  static (Clip left, Clip right) _splitClip(
    Clip clip,
    Duration leftDuration,
    Duration rightDuration,
  ) {
    final rightStart = clip.start + leftDuration;
    final rightId = IdGenerator.clip();

    // Animation on the right half restarts at zero, so keyframes shift back by
    // the length of the left half.
    final rightTransform =
        clip.transform.shifted(-leftDuration).clampedTo(rightDuration);
    final leftTransform = clip.transform.clampedTo(leftDuration);
    final rightMask = clip.mask.shifted(-leftDuration).clampedTo(rightDuration);
    final leftMask = clip.mask.clampedTo(leftDuration);
    final rightEffects = _shiftEffects(clip.effects, -leftDuration);

    switch (clip) {
      case VideoClip():
        // For a reversed clip the first half plays the *tail* of the source
        // window, so the source ranges swap relative to the forward case.
        final leftSourceIn = clip.reversed
            ? clip.sourceOut - TimeUtils.unscale(leftDuration, clip.speed)
            : clip.sourceIn;
        final rightSourceIn = clip.reversed
            ? clip.sourceIn
            : clip.sourceIn + TimeUtils.unscale(leftDuration, clip.speed);
        return (
          clip.copyWith(
            duration: leftDuration,
            sourceIn: leftSourceIn,
            transform: leftTransform,
            mask: leftMask,
            volume: clip.volume.clampedTo(leftDuration),
            audioFadeOut: Duration.zero,
            clearTransition: true,
          ),
          clip.copyWith(
            id: rightId,
            start: rightStart,
            duration: rightDuration,
            sourceIn: rightSourceIn,
            transform: rightTransform,
            mask: rightMask,
            effects: rightEffects,
            volume: clip.volume.shifted(-leftDuration).clampedTo(rightDuration),
            audioFadeIn: Duration.zero,
          ),
        );

      case AudioClip():
        final leftSourceIn = clip.reversed
            ? clip.sourceOut - TimeUtils.unscale(leftDuration, clip.speed)
            : clip.sourceIn;
        final rightSourceIn = clip.reversed
            ? clip.sourceIn
            : clip.sourceIn + TimeUtils.unscale(leftDuration, clip.speed);
        return (
          clip.copyWith(
            duration: leftDuration,
            sourceIn: leftSourceIn,
            mask: leftMask,
            volume: clip.volume.clampedTo(leftDuration),
            fadeOut: Duration.zero,
            clearTransition: true,
          ),
          clip.copyWith(
            id: rightId,
            start: rightStart,
            duration: rightDuration,
            sourceIn: rightSourceIn,
            mask: rightMask,
            effects: rightEffects,
            volume: clip.volume.shifted(-leftDuration).clampedTo(rightDuration),
            fadeIn: Duration.zero,
          ),
        );

      case ImageClip():
        return (
          clip.copyWith(
            duration: leftDuration,
            transform: leftTransform,
            mask: leftMask,
            clearTransition: true,
          ),
          clip.copyWith(
            id: rightId,
            start: rightStart,
            duration: rightDuration,
            transform: rightTransform,
            mask: rightMask,
            effects: rightEffects,
          ),
        );

      case TextClip():
        return (
          clip.copyWith(
            duration: leftDuration,
            transform: leftTransform,
            mask: leftMask,
            clearTransition: true,
          ),
          clip.copyWith(
            id: rightId,
            start: rightStart,
            duration: rightDuration,
            transform: rightTransform,
            mask: rightMask,
            effects: rightEffects,
          ),
        );

      case StickerClip():
        return (
          clip.copyWith(
            duration: leftDuration,
            transform: leftTransform,
            mask: leftMask,
            clearTransition: true,
          ),
          clip.copyWith(
            id: rightId,
            start: rightStart,
            duration: rightDuration,
            transform: rightTransform,
            mask: rightMask,
            effects: rightEffects,
          ),
        );
    }
  }

  // ── Trim ─────────────────────────────────────────────────────────────

  /// Drags the head of a clip. The clip's start moves; its content stays put on
  /// the timeline (the source in-point moves with it), which is what "trim"
  /// means as opposed to "slip".
  static Result<Timeline> trimStart(
    Timeline timeline,
    String clipId,
    Duration newStart,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final snapped = TimeUtils.snapToFrame(newStart, timeline.fps);
    final maxStart = clip.end - AppConstants.minClipDuration;
    final clamped = TimeUtils.clamp(snapped, Duration.zero, maxStart);
    final delta = clamped - clip.start;
    if (delta == Duration.zero) return Result.ok(timeline);

    // A head-trim outward is only legal into free space.
    final previous = track.previousClipBefore(clip.start);
    if (previous != null && clamped < previous.end) {
      return const Result.err(
        InvalidEditFailure('Cannot extend over the previous clip.'),
      );
    }

    if (clip is MediaClip) {
      final sourceDelta = TimeUtils.unscale(delta, clip.speed);
      final newSourceIn = clip.reversed ? clip.sourceIn : clip.sourceIn + sourceDelta;
      if (newSourceIn < Duration.zero) {
        return const Result.err(
          InvalidEditFailure('No more source material at the head.'),
        );
      }
    }

    final newDuration = clip.end - clamped;
    final trimmed = _retimeHead(clip, clamped, newDuration, delta);
    return Result.ok(timeline.replaceTrack(track.replaceClip(trimmed)));
  }

  static Clip _retimeHead(
    Clip clip,
    Duration newStart,
    Duration newDuration,
    Duration delta,
  ) {
    final transform = clip.transform.shifted(-delta).clampedTo(newDuration);
    final mask = clip.mask.shifted(-delta).clampedTo(newDuration);
    switch (clip) {
      case VideoClip():
        return clip.copyWith(
          start: newStart,
          duration: newDuration,
          sourceIn: clip.reversed
              ? clip.sourceIn
              : clip.sourceIn + clip.integrateSpeed(Duration.zero, delta),
          transform: transform,
          mask: mask,
          volume: clip.volume.shifted(-delta).clampedTo(newDuration),
        );
      case AudioClip():
        return clip.copyWith(
          start: newStart,
          duration: newDuration,
          sourceIn: clip.reversed
              ? clip.sourceIn
              : clip.sourceIn + clip.integrateSpeed(Duration.zero, delta),
          mask: mask,
          volume: clip.volume.shifted(-delta).clampedTo(newDuration),
        );
      case ImageClip():
        return clip.copyWith(
          start: newStart,
          duration: newDuration,
          transform: transform,
          mask: mask,
        );
      case TextClip():
        return clip.copyWith(
          start: newStart,
          duration: newDuration,
          transform: transform,
          mask: mask,
        );
      case StickerClip():
        return clip.copyWith(
          start: newStart,
          duration: newDuration,
          transform: transform,
          mask: mask,
        );
    }
  }

  /// Drags the tail of a clip.
  static Result<Timeline> trimEnd(
    Timeline timeline,
    String clipId,
    Duration newEnd, {
    Duration? sourceLimit,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final snapped = TimeUtils.snapToFrame(newEnd, timeline.fps);
    final minEnd = clip.start + AppConstants.minClipDuration;
    var clamped = TimeUtils.max(snapped, minEnd);

    final next = track.nextClipAfter(clip.start);
    if (next != null && clamped > next.start) {
      clamped = next.start;
      if (clamped <= minEnd) {
        return const Result.err(
          InvalidEditFailure('No room to extend before the next clip.'),
        );
      }
    }

    var newDuration = clamped - clip.start;

    // Media clips cannot be extended past the end of their source file.
    if (clip is MediaClip && sourceLimit != null) {
      final available = clip.reversed
          ? clip.sourceOut
          : sourceLimit - clip.sourceIn;
      final maxTimeline = TimeUtils.scale(available, clip.speed);
      if (newDuration > maxTimeline) newDuration = maxTimeline;
      if (newDuration < AppConstants.minClipDuration) {
        return const Result.err(
          InvalidEditFailure('No more source material at the tail.'),
        );
      }
    }

    final trimmed = clip.copyWithBase(
      duration: newDuration,
      transform: clip.transform.clampedTo(newDuration),
      mask: clip.mask.clampedTo(newDuration),
    );
    return Result.ok(timeline.replaceTrack(track.replaceClip(trimmed)));
  }

  // ── Move ─────────────────────────────────────────────────────────────

  /// Moves a clip along its track, or to a different compatible track.
  static Result<Timeline> move(
    Timeline timeline,
    String clipId,
    Duration newStart, {
    String? targetTrackId,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (sourceTrack, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final destination = targetTrackId == null
        ? sourceTrack
        : timeline.trackById(targetTrackId);
    if (destination == null) {
      return const Result.err(InvalidEditFailure('Target track not found.'));
    }
    if (destination.locked) {
      return const Result.err(InvalidEditFailure('Target track is locked.'));
    }
    if (!destination.type.accepts(clip.kind)) {
      return Result.err(
        InvalidEditFailure(
          'A ${clip.kind.id} clip cannot go on a ${destination.type.label} track.',
        ),
      );
    }

    final snapped = TimeUtils.snapToFrame(
      TimeUtils.max(newStart, Duration.zero),
      timeline.fps,
    );
    final moved = clip.copyWithBase(start: snapped, trackId: destination.id);

    if (destination.hasCollision(moved, ignoreClipId: clipId)) {
      return const Result.err(
        InvalidEditFailure('That position overlaps another clip.'),
      );
    }

    if (destination.id == sourceTrack.id) {
      return Result.ok(timeline.replaceTrack(sourceTrack.replaceClip(moved)));
    }
    return Result.ok(
      timeline
          .replaceTrack(sourceTrack.removeClip(clipId))
          .replaceTrack(destination.addClip(moved)),
    );
  }

  // ── Delete ───────────────────────────────────────────────────────────

  /// Removes a clip. With [ripple] the following clips slide back to close the
  /// gap; without it a hole is left behind.
  static Result<Timeline> delete(
    Timeline timeline,
    String clipId, {
    bool ripple = false,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    var next = track.removeClip(clipId);
    if (ripple) {
      next = next.withClips(
        next.clips
            .map(
              (c) => c.start >= clip.end
                  ? c.copyWithBase(start: c.start - clip.duration)
                  : c,
            )
            .toList(),
      );
    }
    return Result.ok(timeline.replaceTrack(next));
  }

  static Result<Timeline> deleteMany(
    Timeline timeline,
    Iterable<String> clipIds, {
    bool ripple = false,
  }) {
    var current = timeline;
    for (final id in clipIds) {
      final result = delete(current, id, ripple: ripple);
      // A missing clip mid-batch is not fatal — it may already be gone.
      if (result.isOk) current = result.valueOrNull!;
    }
    return Result.ok(current);
  }

  // ── Duplicate ────────────────────────────────────────────────────────

  /// Copies a clip and places it immediately after the original, sliding later
  /// clips along to make room.
  static Result<Timeline> duplicate(Timeline timeline, String clipId) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;

    final copy = _withNewId(clip, clip.end);
    final shifted = track.clips
        .map(
          (c) => c.start >= clip.end
              ? c.copyWithBase(start: c.start + clip.duration)
              : c,
        )
        .toList();
    return Result.ok(
      timeline.replaceTrack(track.withClips([...shifted, copy])),
    );
  }

  static Clip _withNewId(Clip clip, Duration start) {
    final id = IdGenerator.clip();
    return switch (clip) {
      VideoClip() => clip.copyWith(id: id, start: start, clearTransition: true),
      AudioClip() => clip.copyWith(id: id, start: start, clearTransition: true),
      ImageClip() => clip.copyWith(id: id, start: start, clearTransition: true),
      TextClip() => clip.copyWith(id: id, start: start, clearTransition: true),
      StickerClip() => clip.copyWith(id: id, start: start, clearTransition: true),
    };
  }

  // ── Speed ────────────────────────────────────────────────────────────

  /// Changes playback rate. The clip's timeline length changes inversely, and
  /// following clips ripple so the cut pattern after it is preserved.
  static Result<Timeline> setSpeed(
    Timeline timeline,
    String clipId,
    double speed, {
    bool ripple = true,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip is! MediaClip) {
      return const Result.err(
        InvalidEditFailure('Only video and audio clips have a speed.'),
      );
    }

    final clamped = MathUtils.clamp(
      speed,
      AppConstants.minClipSpeed,
      AppConstants.maxClipSpeed,
    );
    if ((clamped - clip.speed).abs() < 1e-6) return Result.ok(timeline);

    // Keep the same source material; only its timeline footprint changes.
    final newDuration = TimeUtils.snapToFrame(
      TimeUtils.scale(clip.sourceDuration, clamped),
      timeline.fps,
    );
    if (newDuration < AppConstants.minClipDuration) {
      return const Result.err(
        InvalidEditFailure('That speed would make the clip shorter than a frame.'),
      );
    }

    final delta = newDuration - clip.duration;
    final timeFactor = clip.duration.inMicroseconds == 0
        ? 1.0
        : newDuration.inMicroseconds / clip.duration.inMicroseconds;

    final Clip retimed = switch (clip) {
      VideoClip() => clip.copyWith(
        speed: clamped,
        duration: newDuration,
        transform: clip.transform.timeScaled(timeFactor),
        volume: clip.volume.timeScaled(timeFactor),
        effects: _scaleEffects(clip.effects, timeFactor),
      ),
      AudioClip() => clip.copyWith(
        speed: clamped,
        duration: newDuration,
        volume: clip.volume.timeScaled(timeFactor),
        effects: _scaleEffects(clip.effects, timeFactor),
      ),
      ImageClip() => clip,
    };

    var nextTrack = track.replaceClip(retimed);
    if (ripple && delta != Duration.zero) {
      nextTrack = nextTrack.withClips(
        nextTrack.clips
            .map(
              (c) => c.id != clip.id && c.start >= clip.end
                  ? c.copyWithBase(start: c.start + delta)
                  : c,
            )
            .toList(),
      );
    }
    return Result.ok(timeline.replaceTrack(nextTrack));
  }

  /// Flips playback direction. Timeline geometry is unchanged — only which end
  /// of the source window plays first.
  static Result<Timeline> reverse(Timeline timeline, String clipId) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    final Clip? flipped = switch (clip) {
      VideoClip() => clip.copyWith(reversed: !clip.reversed),
      AudioClip() => clip.copyWith(reversed: !clip.reversed),
      _ => null,
    };
    if (flipped == null) {
      return const Result.err(
        InvalidEditFailure('Only video and audio clips can be reversed.'),
      );
    }
    return Result.ok(timeline.replaceTrack(track.replaceClip(flipped)));
  }

  // ── Freeze frame ─────────────────────────────────────────────────────

  /// Splits at [at] and inserts a still of that frame lasting [holdDuration].
  ///
  /// Implemented as three clips (before / frozen / after) rather than a special
  /// clip type, so every other operation keeps working on the result.
  static Result<Timeline> freezeFrame(
    Timeline timeline,
    String clipId,
    Duration at, {
    Duration holdDuration = const Duration(seconds: 2),
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (_, original) = found;
    if (original is! VideoClip) {
      return const Result.err(
        InvalidEditFailure('Freeze frame only applies to video clips.'),
      );
    }

    final frozenSourceTime = original.sourceTimeAt(at);

    final splitResult = split(timeline, clipId, at);
    if (splitResult.isErr) return splitResult;
    var next = splitResult.valueOrNull!;

    final track = next.trackById(original.trackId);
    if (track == null) {
      return const Result.err(InvalidEditFailure('Track disappeared.'));
    }

    final cut = TimeUtils.snapToFrame(at, next.fps);
    final hold = TimeUtils.snapToFrame(holdDuration, next.fps);

    final frozen = VideoClip(
      id: IdGenerator.clip(),
      trackId: track.id,
      start: cut,
      duration: hold,
      assetId: original.assetId,
      sourceIn: frozenSourceTime,
      freezeFrameAt: frozenSourceTime,
      label: 'Freeze',
      transform: original.transform.clampedTo(hold),
      effects: original.effects,
      muted: true, // a still frame has no matching audio
    );

    // Push everything at or after the cut later by the hold length.
    final shifted = track.clips
        .map((c) => c.start >= cut ? c.copyWithBase(start: c.start + hold) : c)
        .toList();

    next = next.replaceTrack(track.withClips([...shifted, frozen]));
    return Result.ok(next);
  }

  // ── Geometry ─────────────────────────────────────────────────────────

  /// Rotates by 90° steps, keeping the value in `[0, 360)`.
  static Result<Timeline> rotate(
    Timeline timeline,
    String clipId, {
    int quarterTurns = 1,
  }) => _mapTransform(timeline, clipId, (t) {
    final degrees = (t.rotation.staticValue + quarterTurns * 90) % 360;
    return t.copyWith(rotation: t.rotation.withStatic(degrees));
  });

  static Result<Timeline> flipHorizontal(Timeline timeline, String clipId) =>
      _mapTransform(
        timeline,
        clipId,
        (t) => t.copyWith(flipHorizontal: !t.flipHorizontal),
      );

  static Result<Timeline> flipVertical(Timeline timeline, String clipId) =>
      _mapTransform(
        timeline,
        clipId,
        (t) => t.copyWith(flipVertical: !t.flipVertical),
      );

  static Result<Timeline> crop(
    Timeline timeline,
    String clipId,
    CropRect crop,
  ) {
    if (crop.width <= 0.01 || crop.height <= 0.01) {
      return const Result.err(
        InvalidEditFailure('Crop would leave nothing visible.'),
      );
    }
    return _mapTransform(timeline, clipId, (t) => t.copyWith(crop: crop));
  }

  static Result<Timeline> setOpacity(
    Timeline timeline,
    String clipId,
    double opacity,
  ) => _mapTransform(
    timeline,
    clipId,
    (t) => t.copyWith(
      opacity: t.opacity.withStatic(MathUtils.clamp01(opacity)),
    ),
  );

  static Result<Timeline> _mapTransform(
    Timeline timeline,
    String clipId,
    Transform2D Function(Transform2D transform) transform,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }
    final updated = clip.copyWithBase(transform: transform(clip.transform));
    return Result.ok(timeline.replaceTrack(track.replaceClip(updated)));
  }

  // ── Keyframes ────────────────────────────────────────────────────────

  /// Sets a keyframe on one of a clip's animatable transform channels.
  static Result<Timeline> setTransformKeyframe(
    Timeline timeline,
    String clipId,
    TransformChannel channel,
    Duration localTime,
    double value, {
    Easing easing = Easing.easeInOut,
  }) => _mapTransform(timeline, clipId, (t) {
    final keyframe = Keyframe(time: localTime, value: value, easing: easing);
    return switch (channel) {
      TransformChannel.x => t.copyWith(x: t.x.withKeyframe(keyframe)),
      TransformChannel.y => t.copyWith(y: t.y.withKeyframe(keyframe)),
      TransformChannel.scaleX =>
        t.copyWith(scaleX: t.scaleX.withKeyframe(keyframe)),
      TransformChannel.scaleY =>
        t.copyWith(scaleY: t.scaleY.withKeyframe(keyframe)),
      TransformChannel.rotation =>
        t.copyWith(rotation: t.rotation.withKeyframe(keyframe)),
      TransformChannel.opacity =>
        t.copyWith(opacity: t.opacity.withKeyframe(keyframe)),
    };
  });

  static Result<Timeline> removeTransformKeyframe(
    Timeline timeline,
    String clipId,
    TransformChannel channel,
    Duration localTime,
  ) => _mapTransform(timeline, clipId, (t) => switch (channel) {
    TransformChannel.x => t.copyWith(x: t.x.withoutKeyframeAt(localTime)),
    TransformChannel.y => t.copyWith(y: t.y.withoutKeyframeAt(localTime)),
    TransformChannel.scaleX =>
      t.copyWith(scaleX: t.scaleX.withoutKeyframeAt(localTime)),
    TransformChannel.scaleY =>
      t.copyWith(scaleY: t.scaleY.withoutKeyframeAt(localTime)),
    TransformChannel.rotation =>
      t.copyWith(rotation: t.rotation.withoutKeyframeAt(localTime)),
    TransformChannel.opacity =>
      t.copyWith(opacity: t.opacity.withoutKeyframeAt(localTime)),
  });

  // ── Effects ──────────────────────────────────────────────────────────

  static Result<Timeline> addEffect(
    Timeline timeline,
    String clipId,
    Effect effect,
  ) => _mapClip(
    timeline,
    clipId,
    (clip) => clip.copyWithBase(effects: [...clip.effects, effect]),
  );

  static Result<Timeline> removeEffect(
    Timeline timeline,
    String clipId,
    String effectId,
  ) => _mapClip(
    timeline,
    clipId,
    (clip) => clip.copyWithBase(
      effects: clip.effects.where((e) => e.id != effectId).toList(),
    ),
  );

  static Result<Timeline> updateEffect(
    Timeline timeline,
    String clipId,
    Effect effect,
  ) => _mapClip(timeline, clipId, (clip) {
    final index = clip.effects.indexWhere((e) => e.id == effect.id);
    if (index < 0) return clip;
    final next = List<Effect>.of(clip.effects)..[index] = effect;
    return clip.copyWithBase(effects: next);
  });

  // ── Transitions ──────────────────────────────────────────────────────

  /// Attaches a transition to the join between [clipId] and the next clip.
  ///
  /// The incoming clip is pulled back by the overlap so the two actually cross,
  /// which is what makes the transition visible rather than a cut with a
  /// decoration on it.
  static Result<Timeline> setTransition(
    Timeline timeline,
    String clipId,
    Transition transition,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;

    final index = track.indexOfClip(clipId);
    if (index < 0 || index >= track.clips.length - 1) {
      return const Result.err(
        InvalidEditFailure('A transition needs a following clip.'),
      );
    }
    final next = track.clips[index + 1];

    if (next.start != clip.end) {
      return const Result.err(
        InvalidEditFailure('Clips must be touching to add a transition.'),
      );
    }

    final clamped = transition.clampedTo(clip.duration, next.duration);
    if (clamped.duration < const Duration(milliseconds: 100)) {
      return const Result.err(
        InvalidEditFailure('These clips are too short for a transition.'),
      );
    }

    // A cross-dissolve consumes material from both sides, so the incoming clip
    // must move earlier by the overlap. Everything after it ripples with it,
    // and the track gets shorter by the delta — which is exactly what the user
    // sees in every NLE when they drop a transition on a cut.
    final previousOverlap = clip.outTransition?.overlap ?? Duration.zero;
    final shift = clamped.overlap - previousOverlap;

    final updated = clip.copyWithBase(outTransition: clamped);
    final rippled = <Clip>[
      updated,
      for (var i = 0; i < track.clips.length; i++)
        if (i != index)
          i > index
              ? track.clips[i].copyWithBase(start: track.clips[i].start - shift)
              : track.clips[i],
    ];
    return Result.ok(timeline.replaceTrack(track.withClips(rippled)));
  }

  static Result<Timeline> removeTransition(Timeline timeline, String clipId) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    final overlap = clip.outTransition?.overlap ?? Duration.zero;
    if (overlap == Duration.zero) {
      return _mapClip(
        timeline,
        clipId,
        (c) => c.copyWithBase(clearTransition: true),
      );
    }

    final index = track.indexOfClip(clipId);
    final restored = <Clip>[
      for (var i = 0; i < track.clips.length; i++)
        i == index
            ? track.clips[i].copyWithBase(clearTransition: true)
            : i > index
                ? track.clips[i].copyWithBase(
                    start: track.clips[i].start + overlap,
                  )
                : track.clips[i],
    ];
    return Result.ok(timeline.replaceTrack(track.withClips(restored)));
  }

  // ── Insert ───────────────────────────────────────────────────────────

  /// Appends [clip] to the end of a track, or drops it at [at] if free.
  static Result<Timeline> insertClip(
    Timeline timeline,
    String trackId,
    Clip clip, {
    Duration? at,
  }) {
    final track = timeline.trackById(trackId);
    if (track == null) {
      return const Result.err(InvalidEditFailure('Track not found.'));
    }
    if (!track.type.accepts(clip.kind)) {
      return Result.err(
        InvalidEditFailure(
          'A ${clip.kind.id} clip cannot go on a ${track.type.label} track.',
        ),
      );
    }

    final start = TimeUtils.snapToFrame(at ?? track.duration, timeline.fps);
    final placed = clip.copyWithBase(start: start, trackId: trackId);
    if (track.hasCollision(placed)) {
      // Fall back to appending rather than rejecting the import outright.
      final appended = clip.copyWithBase(
        start: TimeUtils.snapToFrame(track.duration, timeline.fps),
        trackId: trackId,
      );
      return Result.ok(timeline.replaceTrack(track.addClip(appended)));
    }
    return Result.ok(timeline.replaceTrack(track.addClip(placed)));
  }

  // ── Tracks ───────────────────────────────────────────────────────────

  static Result<Timeline> addTrack(Timeline timeline, TrackType type) {
    final existing = timeline.tracks.where((t) => t.type == type).length;
    return Result.ok(
      timeline.addTrack(
        Track(
          id: IdGenerator.track(),
          type: type,
          name: '${type.label} ${existing + 1}',
        ),
      ),
    );
  }

  static Result<Timeline> removeTrack(Timeline timeline, String trackId) {
    final track = timeline.trackById(trackId);
    if (track == null) {
      return const Result.err(InvalidEditFailure('Track not found.'));
    }
    final remaining = timeline.tracks.where((t) => t.type.isVisual).length;
    if (track.type.isVisual && remaining <= 1) {
      return const Result.err(
        InvalidEditFailure('A project needs at least one visual track.'),
      );
    }
    return Result.ok(timeline.removeTrack(trackId));
  }

  // ── Housekeeping ─────────────────────────────────────────────────────

  /// Slides every clip on a track left to remove all gaps.
  static Result<Timeline> closeGaps(Timeline timeline, String trackId) {
    final track = timeline.trackById(trackId);
    if (track == null) {
      return const Result.err(InvalidEditFailure('Track not found.'));
    }
    var cursor = Duration.zero;
    final compacted = <Clip>[];
    for (final clip in track.clips) {
      compacted.add(clip.copyWithBase(start: cursor));
      cursor += clip.duration;
    }
    return Result.ok(timeline.replaceTrack(track.withClips(compacted)));
  }

  // ── Speed ramping ────────────────────────────────────────────────────

  /// Installs a speed curve on a clip, re-timing it to match.
  ///
  /// The clip's timeline length changes because a ramp consumes a different
  /// amount of source than a constant rate would. Following clips ripple so the
  /// cut pattern after it survives.
  static Result<Timeline> setSpeedCurve(
    Timeline timeline,
    String clipId,
    AnimatableDouble? curve, {
    bool ripple = true,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip is! MediaClip) {
      return const Result.err(
        InvalidEditFailure('Only video and audio clips have a speed.'),
      );
    }

    // The source window is fixed; solve for the timeline length that consumes
    // exactly it under the new curve. Bisection, because the relationship has
    // no closed form for an arbitrary eased curve.
    final targetSource = clip.sourceDuration;
    final probe = _withCurve(clip, curve);
    final newDuration = curve == null
        ? TimeUtils.scale(targetSource, clip.speed)
        : _solveDurationFor(probe, targetSource, timeline.fps);

    if (newDuration < AppConstants.minClipDuration) {
      return const Result.err(
        InvalidEditFailure('That ramp would make the clip shorter than a frame.'),
      );
    }

    final delta = newDuration - clip.duration;
    final retimed = _withCurve(clip, curve).copyWithBase(duration: newDuration);

    var nextTrack = track.replaceClip(retimed);
    if (ripple && delta != Duration.zero) {
      nextTrack = nextTrack.withClips(
        nextTrack.clips
            .map(
              (c) => c.id != clip.id && c.start >= clip.end
                  ? c.copyWithBase(start: c.start + delta)
                  : c,
            )
            .toList(),
      );
    }
    return Result.ok(timeline.replaceTrack(nextTrack));
  }

  static MediaClip _withCurve(MediaClip clip, AnimatableDouble? curve) =>
      switch (clip) {
        VideoClip() => clip.copyWith(
          speedCurve: curve,
          clearSpeedCurve: curve == null,
        ),
        AudioClip() => clip.copyWith(
          speedCurve: curve,
          clearSpeedCurve: curve == null,
        ),
        ImageClip() => clip,
      };

  /// Finds the timeline duration whose speed integral equals [targetSource].
  static Duration _solveDurationFor(
    MediaClip clip,
    Duration targetSource,
    int fps,
  ) {
    var lo = AppConstants.minClipDuration.inMicroseconds.toDouble();
    var hi = targetSource.inMicroseconds * (1 / AppConstants.minClipSpeed);

    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      final candidate = clip.copyWithBase(
        duration: Duration(microseconds: mid.round()),
      );
      final consumed = candidate is MediaClip
          ? candidate.sourceDuration.inMicroseconds
          : 0;
      if (consumed < targetSource.inMicroseconds) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return TimeUtils.snapToFrame(
      Duration(microseconds: ((lo + hi) / 2).round()),
      fps,
    );
  }

  // ── Masking ──────────────────────────────────────────────────────────

  static Result<Timeline> setMask(
    Timeline timeline,
    String clipId,
    Mask mask,
  ) => _mapClip(timeline, clipId, (clip) => clip.copyWithBase(mask: mask));

  static Result<Timeline> clearMask(Timeline timeline, String clipId) =>
      _mapClip(timeline, clipId, (clip) => clip.copyWithBase(mask: Mask.none));

  // ── Markers ──────────────────────────────────────────────────────────

  static Result<Timeline> addMarker(
    Timeline timeline,
    Duration at, {
    String label = '',
    MarkerKind kind = MarkerKind.note,
  }) {
    final snapped = TimeUtils.snapToFrame(at, timeline.fps);
    // One marker per frame per kind: a double-tap should not stack two.
    final clash = timeline.markers.any(
      (m) => m.kind == kind && m.time == snapped,
    );
    if (clash) return Result.ok(timeline);

    return Result.ok(
      timeline.copyWith(
        markers: [
          ...timeline.markers,
          Marker(
            id: IdGenerator.sortable('mrk'),
            time: snapped,
            label: label,
            kind: kind,
          ),
        ]..sort((a, b) => a.time.compareTo(b.time)),
      ),
    );
  }

  static Result<Timeline> removeMarker(Timeline timeline, String markerId) =>
      Result.ok(
        timeline.copyWith(
          markers: timeline.markers.where((m) => m.id != markerId).toList(),
        ),
      );

  static Result<Timeline> renameMarker(
    Timeline timeline,
    String markerId,
    String label,
  ) => Result.ok(
    timeline.copyWith(
      markers: timeline.markers
          .map((m) => m.id == markerId ? m.copyWith(label: label) : m)
          .toList(),
    ),
  );

  /// Replaces all beat markers with a freshly detected set.
  static Result<Timeline> setBeatMarkers(
    Timeline timeline,
    List<Duration> beats,
  ) => Result.ok(
    timeline.copyWith(
      markers: [
        ...timeline.markers.where((m) => m.kind != MarkerKind.beat),
        for (final beat in beats)
          Marker(
            id: IdGenerator.sortable('beat'),
            time: TimeUtils.snapToFrame(beat, timeline.fps),
            kind: MarkerKind.beat,
          ),
      ]..sort((a, b) => a.time.compareTo(b.time)),
    ),
  );

  // ── Paste ────────────────────────────────────────────────────────────

  /// Drops copied clips at [at], preserving their relative offsets.
  ///
  /// Each lands on a track accepting its kind, and anything that will not fit
  /// is appended rather than dropped — losing a paste silently is worse than
  /// putting it slightly wrong.
  static Result<Timeline> paste(
    Timeline timeline,
    List<Clip> clips,
    Duration at,
  ) {
    if (clips.isEmpty) return Result.ok(timeline);

    final anchor = clips
        .map((c) => c.start)
        .reduce((a, b) => a < b ? a : b);
    var next = timeline;

    for (final clip in clips) {
      final offset = clip.start - anchor;
      final target = next.trackById(clip.trackId) ??
          next.tracks.where((t) => t.type.accepts(clip.kind)).firstOrNull;
      if (target == null) continue;

      final placed = _withNewId(clip, at + offset)
          .copyWithBase(trackId: target.id);
      final result = insertClip(next, target.id, placed, at: at + offset);
      next = result.getOrElse(next);
    }
    return Result.ok(next);
  }

  static Result<Timeline> _mapClip(
    Timeline timeline,
    String clipId,
    Clip Function(Clip clip) transform,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    return Result.ok(timeline.replaceTrack(track.replaceClip(transform(clip))));
  }

  static List<Effect> _shiftEffects(List<Effect> effects, Duration by) =>
      effects
          .map(
            (e) => e.copyWith(
              intensity: e.intensity.shifted(by),
              params: {
                for (final entry in e.params.entries)
                  entry.key: entry.value.shifted(by),
              },
            ),
          )
          .toList();

  static List<Effect> _scaleEffects(List<Effect> effects, double factor) =>
      effects.map((e) => e.timeScaled(factor)).toList();

  const TimelineOperations._();
}

/// The animatable channels of a [Transform2D], addressable by the UI.
enum TransformChannel {
  x('Position X'),
  y('Position Y'),
  scaleX('Scale X'),
  scaleY('Scale Y'),
  rotation('Rotation'),
  opacity('Opacity');

  const TransformChannel(this.label);
  final String label;
}
