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
import '../entities/layer_frame.dart';
import '../entities/marker.dart';
import '../entities/mask.dart';
import '../entities/text_style_spec.dart';
import '../entities/timeline.dart';
import '../entities/track.dart';
import '../entities/transform2d.dart';
import '../entities/transition.dart';
import '../entities/voice_effect.dart';

abstract final class TimelineOperations {
  // ── Split ────────────────────────────────────────────────────────────

  /// Cuts [clipId] at [at], producing two clips that together occupy exactly
  /// the original span.
  static Result<Timeline> split(Timeline timeline, String clipId, Duration at) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    if (clip is CompoundClip) {
      // Splitting a window over grouped content has no honest meaning —
      // which half owns a member that straddles the cut? Ungroup first.
      return const Result.err(
        InvalidEditFailure('Ungroup before splitting a grouped clip.'),
      );
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
    final rightTransform = clip.transform
        .shifted(-leftDuration)
        .clampedTo(rightDuration);
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

      case CompoundClip():
        // Unreachable: [split] refuses compounds before dispatching here.
        throw StateError('split() must reject CompoundClip before _splitClip');
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
      final newSourceIn = clip.reversed
          ? clip.sourceIn
          : clip.sourceIn + sourceDelta;
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
      case CompoundClip():
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
      CompoundClip() =>
        clip.copyWith(id: id, start: start, clearTransition: true),
      StickerClip() => clip.copyWith(
        id: id,
        start: start,
        clearTransition: true,
      ),
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
        InvalidEditFailure(
          'That speed would make the clip shorter than a frame.',
        ),
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
    (t) =>
        t.copyWith(opacity: t.opacity.withStatic(MathUtils.clamp01(opacity))),
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
      TransformChannel.scaleX => t.copyWith(
        scaleX: t.scaleX.withKeyframe(keyframe),
      ),
      TransformChannel.scaleY => t.copyWith(
        scaleY: t.scaleY.withKeyframe(keyframe),
      ),
      TransformChannel.rotation => t.copyWith(
        rotation: t.rotation.withKeyframe(keyframe),
      ),
      TransformChannel.opacity => t.copyWith(
        opacity: t.opacity.withKeyframe(keyframe),
      ),
    };
  });

  static Result<Timeline> removeTransformKeyframe(
    Timeline timeline,
    String clipId,
    TransformChannel channel,
    Duration localTime,
  ) => _mapTransform(
    timeline,
    clipId,
    (t) => switch (channel) {
      TransformChannel.x => t.copyWith(x: t.x.withoutKeyframeAt(localTime)),
      TransformChannel.y => t.copyWith(y: t.y.withoutKeyframeAt(localTime)),
      TransformChannel.scaleX => t.copyWith(
        scaleX: t.scaleX.withoutKeyframeAt(localTime),
      ),
      TransformChannel.scaleY => t.copyWith(
        scaleY: t.scaleY.withoutKeyframeAt(localTime),
      ),
      TransformChannel.rotation => t.copyWith(
        rotation: t.rotation.withoutKeyframeAt(localTime),
      ),
      TransformChannel.opacity => t.copyWith(
        opacity: t.opacity.withoutKeyframeAt(localTime),
      ),
    },
  );

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
            ? track.clips[i].copyWithBase(start: track.clips[i].start + overlap)
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
        InvalidEditFailure(
          'That ramp would make the clip shorter than a frame.',
        ),
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

    final anchor = clips.map((c) => c.start).reduce((a, b) => a < b ? a : b);
    var next = timeline;

    for (final clip in clips) {
      final offset = clip.start - anchor;
      final target =
          next.trackById(clip.trackId) ??
          next.tracks.where((t) => t.type.accepts(clip.kind)).firstOrNull;
      if (target == null) continue;

      final placed = _withNewId(
        clip,
        at + offset,
      ).copyWithBase(trackId: target.id);
      final result = insertClip(next, target.id, placed, at: at + offset);
      next = result.getOrElse(next);
    }
    return Result.ok(next);
  }

  // ── Three-point trims ────────────────────────────────────────────────
  //
  // Trim moves a clip's edge. These three move something else instead, and
  // they are what separates an NLE from a clip arranger:
  //
  //   slip  — the source window slides inside a fixed timeline slot: the clip
  //           does not move and the programme length does not change, but a
  //           different part of the take plays.
  //   slide — the clip moves and its neighbours absorb the difference, so the
  //           cut pattern around it stays intact.
  //   roll  — one cut moves: one clip gets longer by exactly what the other
  //           loses.
  //
  // All three are composed from `trimStart`/`trimEnd`/`move`, which already
  // know how source windows, speed and reversal interact. The only thing that
  // needs care is *ordering*: an edit that would momentarily overlap is
  // rejected, so each case frees the space before it fills it.

  /// Slides the source window inside a clip that keeps its timeline slot.
  ///
  /// Positive [by] plays a later part of the take. [sourceLimit] is the asset's
  /// full duration when the caller knows it — the timeline cannot know it, so
  /// without it only the lower bound is enforced.
  static Result<Timeline> slip(
    Timeline timeline,
    String clipId,
    Duration by, {
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
    if (clip is! MediaClip || clip is ImageClip) {
      return const Result.err(
        InvalidEditFailure('Only a video or audio clip has a source window.'),
      );
    }

    // The gesture is measured on the timeline; the window moves in source
    // time, which differs whenever the clip is sped up or slowed down.
    final shift = TimeUtils.unscale(
      TimeUtils.snapToFrame(by, timeline.fps),
      clip.speed,
    );
    final span = clip.sourceDuration;
    final maxIn = sourceLimit == null
        ? null
        : TimeUtils.max(sourceLimit - span, Duration.zero);

    var newIn = clip.sourceIn + shift;
    if (newIn < Duration.zero) newIn = Duration.zero;
    if (maxIn != null && newIn > maxIn) newIn = maxIn;
    if (newIn == clip.sourceIn) return Result.ok(timeline);

    final slipped = switch (clip) {
      VideoClip() => clip.copyWith(sourceIn: newIn),
      AudioClip() => clip.copyWith(sourceIn: newIn),
      _ => null,
    };
    if (slipped == null) {
      return const Result.err(InvalidEditFailure('Cannot slip this clip.'));
    }
    return Result.ok(timeline.replaceTrack(track.replaceClip(slipped)));
  }

  /// Moves a clip between two neighbours, absorbing the move into them.
  ///
  /// The clip's content and length are untouched; the programme length is
  /// untouched. Only the two surrounding cuts move.
  static Result<Timeline> slide(Timeline timeline, String clipId, Duration by) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final delta = TimeUtils.snapToFrame(by, timeline.fps);
    if (delta == Duration.zero) return Result.ok(timeline);

    // `previousClipBefore` is strict, so a clip ending exactly where this one
    // starts — the only case slide cares about — needs a tick of slack.
    final previous = track.previousClipBefore(clip.start + _tick);
    final next = track.nextClipAfter(clip.end - _tick);
    if (previous == null || previous.end != clip.start) {
      return const Result.err(
        InvalidEditFailure(
          'Slide needs a clip butted against this one\'s head.',
        ),
      );
    }
    if (next == null || next.start != clip.end) {
      return const Result.err(
        InvalidEditFailure(
          'Slide needs a clip butted against this one\'s tail.',
        ),
      );
    }
    if (previous.locked || next.locked) {
      return const Result.err(
        InvalidEditFailure('A neighbouring clip is locked.'),
      );
    }

    // `trimStart`/`trimEnd` clamp rather than refuse, which is right when a
    // user is dragging an edge but wrong here: a clamped slide would move the
    // clip a different distance than asked and quietly desync the two cuts.
    final headroom = _slideLimits(previous, next);
    if (delta < headroom.$1 || delta > headroom.$2) {
      return const Result.err(
        InvalidEditFailure('A neighbouring clip would be too short.'),
      );
    }

    // Free the space on the side we are moving towards before moving into it.
    final steps = delta > Duration.zero
        ? <Result<Timeline> Function(Timeline)>[
            (t) => trimStart(t, next.id, next.start + delta),
            (t) => move(t, clipId, clip.start + delta),
            (t) => trimEnd(t, previous.id, previous.end + delta),
          ]
        : <Result<Timeline> Function(Timeline)>[
            (t) => trimEnd(t, previous.id, previous.end + delta),
            (t) => move(t, clipId, clip.start + delta),
            (t) => trimStart(t, next.id, next.start + delta),
          ];

    return _sequence(timeline, steps);
  }

  /// Moves a single cut, lengthening one clip by exactly what the other loses.
  ///
  /// [atStart] rolls the cut at the clip's head instead of its tail.
  static Result<Timeline> roll(
    Timeline timeline,
    String clipId,
    Duration by, {
    bool atStart = false,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final delta = TimeUtils.snapToFrame(by, timeline.fps);
    if (delta == Duration.zero) return Result.ok(timeline);

    // Name the two sides of the cut, then the logic is the same either way:
    // `left` gives up what `right` gains, or the reverse.
    final Clip left;
    final Clip right;
    if (atStart) {
      final previous = track.previousClipBefore(clip.start + _tick);
      if (previous == null || previous.end != clip.start) {
        return const Result.err(
          InvalidEditFailure('There is no cut at this clip\'s head to roll.'),
        );
      }
      left = previous;
      right = clip;
    } else {
      final next = track.nextClipAfter(clip.end - _tick);
      if (next == null || next.start != clip.end) {
        return const Result.err(
          InvalidEditFailure('There is no cut at this clip\'s tail to roll.'),
        );
      }
      left = clip;
      right = next;
    }
    if (left.locked || right.locked) {
      return const Result.err(
        InvalidEditFailure('A clip at this cut is locked.'),
      );
    }

    // Same reason as slide: refuse rather than let the underlying trims clamp
    // to something the user did not ask for.
    final headroom = _slideLimits(left, right);
    if (delta < headroom.$1 || delta > headroom.$2) {
      return const Result.err(
        InvalidEditFailure('The cut cannot move that far.'),
      );
    }

    final cut = left.end;
    final steps = delta > Duration.zero
        ? <Result<Timeline> Function(Timeline)>[
            (t) => trimStart(t, right.id, cut + delta),
            (t) => trimEnd(t, left.id, cut + delta),
          ]
        : <Result<Timeline> Function(Timeline)>[
            (t) => trimEnd(t, left.id, cut + delta),
            (t) => trimStart(t, right.id, cut + delta),
          ];

    return _sequence(timeline, steps);
  }

  /// How far a cut between [left] and [right] may travel before one of them
  /// falls below the minimum clip length, as `(most negative, most positive)`.
  static (Duration, Duration) _slideLimits(Clip left, Clip right) => (
    AppConstants.minClipDuration - left.duration,
    right.duration - AppConstants.minClipDuration,
  );

  /// Runs [steps] in order, failing the whole edit if any step fails.
  ///
  /// A partially applied compound edit would be worse than none — the user
  /// would have to undo something they never asked for.
  static Result<Timeline> _sequence(
    Timeline timeline,
    List<Result<Timeline> Function(Timeline)> steps,
  ) {
    var next = timeline;
    for (final step in steps) {
      final result = step(next);
      if (result is Err<Timeline>) return result;
      next = result.getOrElse(next);
    }
    return Result.ok(next);
  }

  /// One microsecond — used to look "just inside" a clip when asking a track
  /// what comes next, so the clip does not find itself.
  static const _tick = Duration(microseconds: 1);

  // ── Razor across many cuts ───────────────────────────────────────────

  /// Cuts every clip in [clipIds] at every time in [times].
  ///
  /// This is what turns detected beats into an edit. Times that fall outside a
  /// clip, or too close to an edge to leave a usable piece, are skipped rather
  /// than failing the batch — a beat track always has some beats that land in
  /// silence.
  ///
  /// Cuts are applied latest-first so that earlier times still refer to the
  /// same piece of media: splitting at 2s changes what lives at 5s, but
  /// splitting at 5s never changes what lives at 2s.
  static Result<Timeline> razor(
    Timeline timeline,
    Iterable<Duration> times, {
    Iterable<String>? clipIds,
  }) {
    final sorted = times.toList()..sort();
    if (sorted.isEmpty) {
      return const Result.err(InvalidEditFailure('No cut points.'));
    }

    final targets = clipIds?.toSet();
    var next = timeline;
    var cuts = 0;

    for (final at in sorted.reversed) {
      for (final track in next.tracks) {
        if (track.locked) continue;
        final clip = track.clipAt(at);
        if (clip == null || clip.locked) continue;
        if (targets != null && !targets.contains(clip.id)) continue;

        final result = split(next, clip.id, at);
        result.fold((updated) {
          next = updated;
          cuts++;
        }, (_) {});
      }
    }

    if (cuts == 0) {
      return const Result.err(
        InvalidEditFailure('No cut point landed inside a clip.'),
      );
    }
    return Result.ok(next);
  }

  // ── Audio crossfade ──────────────────────────────────────────────────

  /// Sets an equal-power crossfade at the cut after [clipId].
  ///
  /// The two clips must be butted. Implemented as a paired fade-out/fade-in
  /// of [duration] centred on the joint — the clips do not move and no
  /// overlap is created, so every other edit keeps working. The equal-power
  /// curves are what make this a crossfade rather than a dip: their sum
  /// holds unity through the joint (the export uses `afade curve=qsin`).
  static Result<Timeline> setAudioCrossfade(
    Timeline timeline,
    String clipId,
    Duration duration,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip is! AudioClip) {
      return const Result.err(
        InvalidEditFailure('Audio crossfades join two audio clips.'),
      );
    }
    final next = track.nextClipAfter(clip.end - _tick);
    if (next is! AudioClip || next.start != clip.end) {
      return const Result.err(
        InvalidEditFailure('The next audio clip must touch this one.'),
      );
    }
    if (clip.locked || next.locked) {
      return const Result.err(InvalidEditFailure('A clip here is locked.'));
    }

    final half = TimeUtils.snapToFrame(
      Duration(microseconds: duration.inMicroseconds ~/ 2),
      timeline.fps,
    );
    final maxHalf = TimeUtils.min(
      Duration(microseconds: clip.duration.inMicroseconds ~/ 2),
      Duration(microseconds: next.duration.inMicroseconds ~/ 2),
    );
    final clamped = TimeUtils.min(half, maxHalf);
    if (clamped <= Duration.zero) {
      return const Result.err(
        InvalidEditFailure('Too short for a crossfade here.'),
      );
    }

    return Result.ok(
      timeline.replaceTrack(
        track
            .replaceClip(clip.copyWith(fadeOut: clamped))
            .replaceClip(next.copyWith(fadeIn: clamped)),
      ),
    );
  }

  // ── Audio character ──────────────────────────────────────────────────

  /// Updates an audio clip's voice properties in one edit.
  static Result<Timeline> updateAudioCharacter(
    Timeline timeline,
    String clipId, {
    double? pitchSemitones,
    bool? preservePitch,
    VoiceEffect? voiceEffect,
  }) {
    final clip = timeline.findClip(clipId)?.$2;
    if (clip is! AudioClip) {
      return const Result.err(
        InvalidEditFailure('Voice settings apply to audio clips.'),
      );
    }
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }
    return _mapClip(
      timeline,
      clipId,
      (c) => (c as AudioClip).copyWith(
        pitchSemitones: pitchSemitones?.clamp(-12.0, 12.0),
        preservePitch: preservePitch,
        voiceEffect: voiceEffect,
      ),
    );
  }

  // ── Multicam ─────────────────────────────────────────────────────────

  /// Cuts [clipId] at [at] and swaps the second half to [angle].
  ///
  /// This is the whole multicam gesture: while watching, tap an angle and the
  /// programme switches there from that instant. It is a razor plus a media
  /// swap, so the result is two ordinary clips — trimmable, re-swappable, and
  /// invisible to everything downstream. No multicam mode to be stuck in.
  ///
  /// [angleSourceIn] is where that angle's own footage sits at this timeline
  /// instant; the caller knows the sync offsets, so it computes that rather
  /// than this guessing.
  static Result<Timeline> switchAngle(
    Timeline timeline,
    String clipId,
    Duration at, {
    required String angleAssetId,
    required Duration angleSourceIn,
    String? angleLabel,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final clip = found.$2;
    if (clip is! VideoClip) {
      return const Result.err(
        InvalidEditFailure('Angle switching works on video clips.'),
      );
    }

    // Already showing this angle: switching again would split for nothing.
    if (clip.assetId == angleAssetId && clip.containsTime(at)) {
      return const Result.err(
        InvalidEditFailure('That angle is already on screen here.'),
      );
    }

    final cut = split(timeline, clipId, at);
    if (cut is Err<Timeline>) return cut;
    var next = cut.getOrElse(timeline);

    // The right-hand piece is the one to re-point; find it by position
    // rather than id, because `split` mints a fresh id for it.
    final track = next.trackById(clip.trackId);
    final second = track?.clipAt(at);
    if (second is! VideoClip) {
      return const Result.err(
        InvalidEditFailure('Internal error switching the angle.'),
      );
    }

    next = next.replaceTrack(
      track!.replaceClip(
        second.copyWith(
          assetId: angleAssetId,
          sourceIn: angleSourceIn,
          label: angleLabel ?? second.label,
        ),
      ),
    );
    return Result.ok(next);
  }

  // ── Grouping ─────────────────────────────────────────────────────────

  /// Bundles [clipIds] into one [CompoundClip] on their shared track.
  ///
  /// Single-track by design (v1): members must all live on one visual track.
  /// Grouping across tracks is refused with a message rather than
  /// half-supported — a compound that silently dropped its other tracks
  /// would be worse than none.
  static Result<Timeline> group(Timeline timeline, Set<String> clipIds) {
    if (clipIds.length < 2) {
      return const Result.err(
        InvalidEditFailure('Select at least two clips to group.'),
      );
    }

    final members = <Clip>[];
    Track? host;
    for (final id in clipIds) {
      final found = timeline.findClip(id);
      if (found == null) {
        return const Result.err(InvalidEditFailure('Clip not found.'));
      }
      final (track, clip) = found;
      if (host != null && track.id != host.id) {
        return const Result.err(
          InvalidEditFailure(
            'Grouping works within one track — group each track separately.',
          ),
        );
      }
      host = track;
      if (clip.locked) {
        return const Result.err(
          InvalidEditFailure('A locked clip cannot be grouped.'),
        );
      }
      if (clip is CompoundClip) {
        return const Result.err(
          InvalidEditFailure('Groups cannot contain groups.'),
        );
      }
      members.add(clip);
    }
    if (host == null || !host.type.isVisual) {
      return const Result.err(
        InvalidEditFailure('Grouping works on video and overlay tracks.'),
      );
    }

    members.sort((a, b) => a.start.compareTo(b.start));
    final from = members.first.start;
    final to = members.map((c) => c.end).reduce(TimeUtils.max);

    // A stranger inside the span would collide with the block. The user can
    // see exactly which clip is in the way, so name it.
    for (final other in host.clips) {
      if (clipIds.contains(other.id)) continue;
      if (other.start < to && from < other.end) {
        return Result.err(
          InvalidEditFailure(
            'The selection wraps around "'
            '${other.label ?? other.kind.id}" — include it or move it first.',
          ),
        );
      }
    }

    // The last member's outgoing transition points at a clip that is no
    // longer its neighbour, so it is dropped; the ones between members ride
    // along inside.
    final inner = <Clip>[
      for (final (index, clip) in members.indexed)
        clip.copyWithBase(
          start: clip.start - from,
          trackId: 'inner',
          clearTransition: index == members.length - 1,
        ),
    ];

    final compound = CompoundClip(
      id: IdGenerator.clip(),
      trackId: host.id,
      start: from,
      duration: to - from,
      innerClips: inner,
      label: 'Group · ${inner.length}',
    );

    final nextTrack = host.withClips([
      ...host.clips.where((c) => !clipIds.contains(c.id)),
      compound,
    ]);
    return Result.ok(timeline.replaceTrack(nextTrack));
  }

  /// Dissolves a compound back into its members, exactly where they were.
  static Result<Timeline> ungroup(Timeline timeline, String clipId) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip is! CompoundClip) {
      return const Result.err(InvalidEditFailure('That is not a group.'));
    }
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final restored = <Clip>[
      for (final inner in clip.innerClips)
        inner.copyWithBase(
          start: clip.start + inner.start,
          trackId: track.id,
        ),
    ];

    // The compound may have been moved next to other clips since grouping;
    // its window fit, but a member trimmed shorter than the window did not
    // reserve the space. Check every landing spot.
    final others = track.clips.where((c) => c.id != clipId).toList();
    for (final member in restored) {
      for (final other in others) {
        if (member.overlaps(other)) {
          return const Result.err(
            InvalidEditFailure('Not enough room here to ungroup.'),
          );
        }
      }
    }

    return Result.ok(
      timeline.replaceTrack(track.withClips([...others, ...restored])),
    );
  }

  // ── Silence removal ──────────────────────────────────────────────────

  /// Cuts [sourceSpans] (ranges of the clip's *asset*, in source time) out of
  /// [clipId], closing each gap.
  ///
  /// Spans are applied latest-first for the same reason [razor] works that
  /// way: removing 40–42s never moves what lives at 10s, so earlier spans
  /// stay valid while later ones are consumed.
  ///
  /// Only the named clip's track ripples. That is the honest jump-cut
  /// behaviour — other tracks (music, titles) hold position, exactly like
  /// every NLE's single-track ripple.
  static Result<Timeline> removeSilences(
    Timeline timeline,
    String clipId,
    List<({Duration start, Duration end})> sourceSpans,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final clip = found.$2;
    if (clip is! MediaClip) {
      return const Result.err(
        InvalidEditFailure('Only audio or video can have silences removed.'),
      );
    }
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }
    if (clip.reversed) {
      return const Result.err(
        InvalidEditFailure(
          'Un-reverse the clip first — silence positions flip with it.',
        ),
      );
    }
    if (clip.hasSpeedRamp) {
      return const Result.err(
        InvalidEditFailure('Remove the speed ramp first.'),
      );
    }

    // Source time → timeline time, for this clip's window and speed.
    Duration toTimeline(Duration source) =>
        clip.start + TimeUtils.scale(source - clip.sourceIn, clip.speed);

    // Clamp to the clip's window, convert, keep only spans big enough to
    // matter once snapped to frames.
    final ranges = <({Duration start, Duration end})>[];
    for (final span in sourceSpans) {
      final from = TimeUtils.max(span.start, clip.sourceIn);
      final to = TimeUtils.min(span.end, clip.sourceOut);
      if (to <= from) continue;
      final start = TimeUtils.snapToFrame(toTimeline(from), timeline.fps);
      final end = TimeUtils.snapToFrame(toTimeline(to), timeline.fps);
      if (end - start < AppConstants.minClipDuration) continue;
      ranges.add((start: start, end: end));
    }
    if (ranges.isEmpty) {
      return const Result.err(
        InvalidEditFailure('No removable silence inside this clip.'),
      );
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));

    var next = timeline;
    final currentId = clipId;

    for (final range in ranges.reversed) {
      final target = next.findClip(currentId)?.$2;
      if (target == null) break;

      final touchesHead = range.start <= target.start;
      final touchesTail = range.end >= target.end;

      if (touchesHead && touchesTail) {
        // The whole clip is silence — remove it outright.
        final result = delete(next, currentId, ripple: true);
        if (result is Err<Timeline>) return result;
        next = result.getOrElse(next);
        break;
      } else if (touchesTail) {
        final result = trimEnd(next, currentId, range.start);
        if (result is Err<Timeline>) return result;
        next = result.getOrElse(next);
      } else if (touchesHead) {
        // Trim then close the gap the head-trim leaves behind.
        final trimmed = trimStart(next, currentId, range.end);
        if (trimmed is Err<Timeline>) return trimmed;
        next = trimmed.getOrElse(next);
        final moved = move(next, currentId, range.start);
        if (moved is Err<Timeline>) return moved;
        next = moved.getOrElse(next);
      } else {
        // Interior span: cut both ends, drop the middle, close the gap.
        var result = split(next, currentId, range.end);
        if (result is Err<Timeline>) return result;
        next = result.getOrElse(next);

        result = split(next, currentId, range.start);
        if (result is Err<Timeline>) return result;
        next = result.getOrElse(next);

        final middle = next.findClip(currentId) == null
            ? null
            : next.tracks
                  .firstWhere((t) => t.id == target.trackId)
                  .clipAt(range.start);
        if (middle == null) {
          return const Result.err(
            InvalidEditFailure('Internal error locating the silent piece.'),
          );
        }
        result = delete(next, middle.id, ripple: true);
        if (result is Err<Timeline>) return result;
        next = result.getOrElse(next);
        // Earlier spans live in the left piece, which kept [currentId].
      }
    }

    return Result.ok(next);
  }

  // ── Keyframe shaping ─────────────────────────────────────────────────

  /// Replaces one keyframe on one transform channel, keeping the rest.
  ///
  /// Used by the curve editor to change a segment's easing. The keyframe is
  /// matched by *time* rather than index: the caller is looking at a curve,
  /// not at a list, and an index would silently address the wrong segment if
  /// anything reordered in between.
  static Result<Timeline> setKeyframe(
    Timeline timeline,
    String clipId,
    TransformChannel channel,
    Keyframe replacement,
  ) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final current = _channelOf(clip.transform, channel);
    final index = current.keyframes.indexWhere(
      (k) => k.time == replacement.time,
    );
    if (index < 0) {
      return const Result.err(
        InvalidEditFailure('There is no keyframe at that time.'),
      );
    }

    final updated = AnimatableDouble(
      current.staticValue,
      keyframes: [
        for (final (i, k) in current.keyframes.indexed)
          if (i == index) replacement else k,
      ],
    );

    return Result.ok(
      timeline.replaceTrack(
        track.replaceClip(
          clip.copyWithBase(
            transform: _withChannel(clip.transform, channel, updated),
          ),
        ),
      ),
    );
  }

  static AnimatableDouble _channelOf(
    Transform2D transform,
    TransformChannel channel,
  ) => switch (channel) {
    TransformChannel.x => transform.x,
    TransformChannel.y => transform.y,
    TransformChannel.scaleX => transform.scaleX,
    TransformChannel.scaleY => transform.scaleY,
    TransformChannel.rotation => transform.rotation,
    TransformChannel.opacity => transform.opacity,
  };

  static Transform2D _withChannel(
    Transform2D transform,
    TransformChannel channel,
    AnimatableDouble value,
  ) => switch (channel) {
    TransformChannel.x => transform.copyWith(x: value),
    TransformChannel.y => transform.copyWith(y: value),
    TransformChannel.scaleX => transform.copyWith(scaleX: value),
    TransformChannel.scaleY => transform.copyWith(scaleY: value),
    TransformChannel.rotation => transform.copyWith(rotation: value),
    TransformChannel.opacity => transform.copyWith(opacity: value),
  };

  // ── Captions ─────────────────────────────────────────────────────────

  /// Restyles every caption clip on the timeline in one edit.
  ///
  /// Acts on `isSubtitle` clips only, so hand-placed titles sharing a track
  /// keep their own look — that flag is exactly what it is for.
  static Result<Timeline> restyleCaptions(
    Timeline timeline,
    TextStyleSpec style,
  ) {
    var changed = 0;
    final tracks = <Track>[];
    for (final track in timeline.tracks) {
      if (track.locked) {
        tracks.add(track);
        continue;
      }
      tracks.add(
        track.withClips([
          for (final clip in track.clips)
            if (clip is TextClip && clip.isSubtitle)
              () {
                changed++;
                return clip.copyWith(style: style);
              }()
            else
              clip,
        ]),
      );
    }
    if (changed == 0) {
      return const Result.err(InvalidEditFailure('There are no captions.'));
    }
    return Result.ok(timeline.withTracks(tracks));
  }

  /// Joins a caption to the one after it on its track.
  ///
  /// The merged cue spans both and its text is joined with a space; word
  /// timings survive, shifted into the merged clip's local time, so a merged
  /// karaoke caption keeps highlighting correctly.
  static Result<Timeline> mergeCaption(Timeline timeline, String clipId) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Caption not found.'));
    }
    final (track, clip) = found;
    if (clip is! TextClip) {
      return const Result.err(InvalidEditFailure('That is not a caption.'));
    }
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }

    final next = track.nextClipAfter(clip.end - _tick);
    if (next is! TextClip) {
      return const Result.err(
        InvalidEditFailure('There is no caption after this one to merge.'),
      );
    }

    final gap = next.start - clip.end;
    final merged = clip.copyWith(
      duration: next.end - clip.start,
      text: '${clip.text.trim()} ${next.text.trim()}'.trim(),
      wordTimings: [
        ...clip.wordTimings,
        // The follower's timings are local to *it*; rebase onto the merged
        // clip's zero, which sits at this clip's start.
        for (final w in next.wordTimings)
          w.shifted(clip.duration + gap),
      ],
    );

    return Result.ok(
      timeline.replaceTrack(
        track.withClips([
          for (final c in track.clips)
            if (c.id == clipId) merged else if (c.id != next.id) c,
        ]),
      ),
    );
  }

  /// Shifts every caption by [by], for fixing a systematic sync offset.
  static Result<Timeline> nudgeCaptions(Timeline timeline, Duration by) {
    if (by == Duration.zero) return Result.ok(timeline);

    var changed = 0;
    final tracks = <Track>[];
    for (final track in timeline.tracks) {
      if (track.locked) {
        tracks.add(track);
        continue;
      }
      tracks.add(
        track.withClips([
          for (final clip in track.clips)
            if (clip is TextClip && clip.isSubtitle)
              () {
                changed++;
                // Never before zero: a caption at a negative time simply
                // never renders, which reads as "it deleted my captions".
                final start = clip.start + by;
                return clip.copyWith(
                  start: start < Duration.zero ? Duration.zero : start,
                );
              }()
            else
              clip,
        ]),
      );
    }
    if (changed == 0) {
      return const Result.err(InvalidEditFailure('There are no captions.'));
    }
    return Result.ok(timeline.withTracks(tracks));
  }

  // ── Layout ───────────────────────────────────────────────────────────

  /// Sets a clip's rounded-corner / border dressing.
  static Result<Timeline> setFrame(
    Timeline timeline,
    String clipId,
    LayerFrame frame,
  ) => _mapClip(timeline, clipId, (clip) => clip.copyWithBase(frame: frame));

  /// Positions [clipIds] into a named arrangement.
  ///
  /// Order matters and is the selection's timeline order, so "the first clip
  /// goes top-left" is predictable rather than dependent on set iteration.
  /// Clips beyond the layout's cell count keep their current position — the
  /// alternative, stacking them all in the last cell, only looks like a bug.
  static Result<Timeline> applyLayout(
    Timeline timeline,
    List<String> clipIds,
    SplitLayout layout,
  ) {
    if (clipIds.isEmpty) {
      return const Result.err(InvalidEditFailure('Select some clips first.'));
    }

    final cells = layout.cells;
    var next = timeline;
    var placed = 0;

    for (var i = 0; i < clipIds.length && i < cells.length; i++) {
      final cell = cells[i];
      final found = next.findClip(clipIds[i]);
      if (found == null || found.$2.locked) continue;

      final clip = found.$2;
      final result = _mapClip(
        next,
        clipIds[i],
        (c) => c.copyWithBase(
          transform: clip.transform.copyWith(
            scaleX: AnimatableDouble(cell.scale),
            scaleY: AnimatableDouble(cell.scale),
            x: AnimatableDouble(cell.x),
            y: AnimatableDouble(cell.y),
          ),
        ),
      );
      next = result.getOrElse(next);
      placed++;
    }

    if (placed == 0) {
      return const Result.err(
        InvalidEditFailure('Nothing here could be arranged.'),
      );
    }
    return Result.ok(next);
  }

  // ── Ken Burns ────────────────────────────────────────────────────────

  /// Animates a slow push and drift across a still, as keyframes.
  ///
  /// Deliberately expressed as ordinary transform keyframes rather than a
  /// special clip property: the user can then open the keyframe editor and
  /// change the move, and every other part of the app — preview, export,
  /// speed changes — already handles keyframes.
  ///
  /// [zoom] is the total scale change over the clip (0.15 = a 15% push).
  static Result<Timeline> kenBurns(
    Timeline timeline,
    String clipId, {
    KenBurnsMove move = KenBurnsMove.zoomIn,
    double zoom = 0.18,
  }) {
    final found = timeline.findClip(clipId);
    if (found == null) {
      return const Result.err(InvalidEditFailure('Clip not found.'));
    }
    final (track, clip) = found;
    if (clip.locked) {
      return const Result.err(InvalidEditFailure('This clip is locked.'));
    }
    if (clip.duration <= Duration.zero) {
      return const Result.err(InvalidEditFailure('This clip has no length.'));
    }

    final amount = zoom.clamp(0.02, 1.0);
    final end = clip.duration;

    // Scaling up is what makes panning possible at all: at scale 1 there is
    // nothing outside the frame to pan into, so a pure pan still zooms a
    // little and then travels within that headroom.
    final (fromScale, toScale) = switch (move) {
      KenBurnsMove.zoomIn => (1.0, 1.0 + amount),
      KenBurnsMove.zoomOut => (1.0 + amount, 1.0),
      _ => (1.0 + amount, 1.0 + amount),
    };

    // Travel is limited by the headroom the scale actually creates, so the
    // frame edge is never exposed.
    final headroom = (amount / (1 + amount)) * 0.5;
    final (fromX, toX, fromY, toY) = switch (move) {
      KenBurnsMove.panLeft => (headroom, -headroom, 0.0, 0.0),
      KenBurnsMove.panRight => (-headroom, headroom, 0.0, 0.0),
      KenBurnsMove.panUp => (0.0, 0.0, headroom, -headroom),
      KenBurnsMove.panDown => (0.0, 0.0, -headroom, headroom),
      _ => (0.0, 0.0, 0.0, 0.0),
    };

    // A channel that does not move stays static. Emitting two identical
    // keyframes would make `isAnimated` true and put a pointless track in the
    // keyframe editor.
    AnimatableDouble ramp(double from, double to) => from == to
        ? AnimatableDouble(from)
        : AnimatableDouble(
            from,
            keyframes: [
              // Ease at both ends: a Ken Burns move that starts and stops abruptly
              // reads as a glitch rather than a camera.
              Keyframe(time: Duration.zero, value: from),
              Keyframe(time: end, value: to),
            ],
          );

    final animated = clip.transform.copyWith(
      scaleX: ramp(fromScale, toScale),
      scaleY: ramp(fromScale, toScale),
      x: ramp(fromX, toX),
      y: ramp(fromY, toY),
    );

    return Result.ok(
      timeline.replaceTrack(
        track.replaceClip(clip.copyWithBase(transform: animated)),
      ),
    );
  }

  /// Clears every transform keyframe, leaving the value the clip starts on.
  static Result<Timeline> clearMotion(Timeline timeline, String clipId) =>
      _mapClip(
        timeline,
        clipId,
        (clip) => clip.copyWithBase(transform: clip.transform.frozen()),
      );

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

/// The canned camera moves offered for stills.
enum KenBurnsMove {
  zoomIn('Zoom in'),
  zoomOut('Zoom out'),
  panLeft('Pan left'),
  panRight('Pan right'),
  panUp('Pan up'),
  panDown('Pan down');

  const KenBurnsMove(this.label);
  final String label;

  bool get isZoom =>
      this == KenBurnsMove.zoomIn || this == KenBurnsMove.zoomOut;
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


/// Where each layer sits in a split-screen arrangement.
///
/// Cells are expressed the way the transform is — a scale plus a centre
/// offset in canvas fractions — so a layout is just a batch of ordinary
/// transforms. Nothing about a laid-out clip is special afterwards: it can be
/// nudged, animated or re-laid-out like any other.
enum SplitLayout {
  sideBySide('Side by side', [
    LayoutCell(scale: 0.5, x: -0.25, y: 0),
    LayoutCell(scale: 0.5, x: 0.25, y: 0),
  ]),
  stacked('Stacked', [
    LayoutCell(scale: 0.5, x: 0, y: -0.25),
    LayoutCell(scale: 0.5, x: 0, y: 0.25),
  ]),
  threeUp('Three up', [
    LayoutCell(scale: 1 / 3, x: 0, y: -1 / 3),
    LayoutCell(scale: 1 / 3, x: 0, y: 0),
    LayoutCell(scale: 1 / 3, x: 0, y: 1 / 3),
  ]),
  grid('Grid of four', [
    LayoutCell(scale: 0.5, x: -0.25, y: -0.25),
    LayoutCell(scale: 0.5, x: 0.25, y: -0.25),
    LayoutCell(scale: 0.5, x: -0.25, y: 0.25),
    LayoutCell(scale: 0.5, x: 0.25, y: 0.25),
  ]),
  pictureInPicture('Picture in picture', [
    LayoutCell(scale: 1, x: 0, y: 0),
    LayoutCell(scale: 0.32, x: 0.3, y: -0.32),
  ]);

  const SplitLayout(this.label, this.cells);

  final String label;
  final List<LayoutCell> cells;

  int get capacity => cells.length;
}

class LayoutCell {
  const LayoutCell({required this.scale, required this.x, required this.y});

  final double scale;
  final double x;
  final double y;
}
