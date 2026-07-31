/// Stepping inside a group and back out.
///
/// The enter/exit round trip is the risky part: an edit made inside must
/// survive coming out, and nothing may be silently dropped. These tests build
/// the swap the controller performs and check the arithmetic, without a
/// widget tree or a Riverpod container.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';

VideoClip _clip(String id, int startSec, int lenSec) => VideoClip(
  id: id,
  trackId: 'v1',
  start: Duration(seconds: startSec),
  duration: Duration(seconds: lenSec),
  assetId: 'a',
);

/// A timeline with one group of two clips, plus a clip after it.
({Timeline timeline, String compoundId}) _grouped() {
  final flat = Timeline(
    fps: 30,
    tracks: [
      Track(
        id: 'v1',
        type: TrackType.video,
        clips: [_clip('a', 2, 4), _clip('b', 6, 4), _clip('c', 20, 3)],
      ),
    ],
  );
  final grouped =
      TimelineOperations.group(flat, {'a', 'b'}).valueOrNull!;
  final id = grouped.tracks.single.clips.whereType<CompoundClip>().single.id;
  return (timeline: grouped, compoundId: id);
}

/// The inner timeline the controller builds on entering.
Timeline _inner(Timeline outer, String compoundId) {
  final compound = outer.findClip(compoundId)!.$2 as CompoundClip;
  return Timeline(
    fps: outer.fps,
    width: outer.width,
    height: outer.height,
    tracks: [
      Track(
        id: 'inner',
        type: TrackType.video,
        clips: [
          for (final clip in compound.innerClips)
            clip.copyWithBase(trackId: 'inner'),
        ],
      ),
    ],
  );
}

/// Writing the inner timeline back, as the controller does on exit.
Timeline _writeBack(Timeline outer, String compoundId, Timeline inner) {
  final found = outer.findClip(compoundId)!;
  final compound = found.$2 as CompoundClip;
  final edited = inner.tracks.expand((t) => t.clips).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final content = edited.isEmpty
      ? Duration.zero
      : edited.map((c) => c.end).reduce((x, y) => x > y ? x : y);
  final windowFollowed =
      (compound.duration - compound.contentDuration).abs() <
      const Duration(milliseconds: 2);

  return outer.replaceTrack(
    found.$1.replaceClip(
      compound.copyWith(
        innerClips: [
          for (final c in edited) c.copyWithBase(trackId: 'inner'),
        ],
        duration: windowFollowed
            ? content
            : (content < compound.duration ? content : compound.duration),
      ),
    ),
  );
}

void main() {
  test('entering shows the members at their own local times', () {
    final (:timeline, :compoundId) = _grouped();
    final inner = _inner(timeline, compoundId);

    expect(inner.tracks.single.clips, hasLength(2));
    expect(inner.tracks.single.clips.first.start, Duration.zero);
    expect(inner.tracks.single.clips.last.start, const Duration(seconds: 4));
    expect(inner.fps, timeline.fps, reason: 'the preview must frame the same');
  });

  test('a round trip with no edits changes nothing', () {
    final (:timeline, :compoundId) = _grouped();
    final restored = _writeBack(
      timeline,
      compoundId,
      _inner(timeline, compoundId),
    );

    final before = timeline.findClip(compoundId)!.$2 as CompoundClip;
    final after = restored.findClip(compoundId)!.$2 as CompoundClip;
    expect(after.start, before.start);
    expect(after.duration, before.duration);
    expect(after.innerClips, hasLength(before.innerClips.length));
  });

  test('an edit made inside survives coming out', () {
    final (:timeline, :compoundId) = _grouped();
    var inner = _inner(timeline, compoundId);

    // Trim the first member and let the second stay where it is.
    inner = TimelineOperations.trimEnd(
      inner,
      inner.tracks.single.clips.first.id,
      const Duration(seconds: 3),
    ).valueOrNull!;

    final restored = _writeBack(timeline, compoundId, inner);
    final compound = restored.findClip(compoundId)!.$2 as CompoundClip;
    expect(compound.innerClips.first.duration, const Duration(seconds: 3));
  });

  test('the group shrinks when its content does, if it was following', () {
    final (:timeline, :compoundId) = _grouped();
    var inner = _inner(timeline, compoundId);

    // Delete the second member: content drops from 8s to 4s.
    inner = TimelineOperations.delete(
      inner,
      inner.tracks.single.clips.last.id,
    ).valueOrNull!;

    final compound =
        _writeBack(timeline, compoundId, inner).findClip(compoundId)!.$2
            as CompoundClip;
    expect(compound.duration, const Duration(seconds: 4));
  });

  test('a deliberately trimmed window keeps its length', () {
    final (:timeline, :compoundId) = _grouped();
    // Trim the group's window to 6s while its content is 8s.
    final trimmed = TimelineOperations.trimEnd(
      timeline,
      compoundId,
      timeline.findClip(compoundId)!.$2.start + const Duration(seconds: 6),
    ).valueOrNull!;

    final restored = _writeBack(
      trimmed,
      compoundId,
      _inner(trimmed, compoundId),
    );
    final compound = restored.findClip(compoundId)!.$2 as CompoundClip;
    expect(
      compound.duration,
      const Duration(seconds: 6),
      reason: 'a window the user set must not spring back to the content',
    );
  });

  test('clips outside the group are untouched by the round trip', () {
    final (:timeline, :compoundId) = _grouped();
    final restored = _writeBack(
      timeline,
      compoundId,
      _inner(timeline, compoundId),
    );
    expect(restored.findClip('c')!.$2.start, const Duration(seconds: 20));
    expect(restored.tracks.single.clips, hasLength(2));
  });

  test('adding a member inside grows the group', () {
    final (:timeline, :compoundId) = _grouped();
    var inner = _inner(timeline, compoundId);

    inner = TimelineOperations.insertClip(
      inner,
      'inner',
      _clip('new', 8, 3).copyWith(trackId: 'inner'),
    ).valueOrNull!;

    final compound =
        _writeBack(timeline, compoundId, inner).findClip(compoundId)!.$2
            as CompoundClip;
    expect(compound.innerClips, hasLength(3));
    expect(compound.duration, const Duration(seconds: 11));
  });
}
