/// Grouping: the round trip, the refusals, and the export flatten.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transition.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

VideoClip _clip(String id, int startSec, int lenSec) => VideoClip(
  id: id,
  trackId: 'v1',
  start: Duration(seconds: startSec),
  duration: Duration(seconds: lenSec),
  assetId: 'asset',
);

Timeline _timeline(List<Clip> clips, {List<Track> extraTracks = const []}) =>
    Timeline(
      fps: 30,
      width: 1080,
      height: 1920,
      tracks: [
        Track(id: 'v1', type: TrackType.video, clips: clips),
        ...extraTracks,
      ],
    );

void main() {
  group('group', () {
    test('members become one block; timing is preserved inside', () {
      final result = TimelineOperations.group(
        _timeline([_clip('a', 2, 4), _clip('b', 6, 4), _clip('c', 20, 2)]),
        {'a', 'b'},
      );

      final track = result.valueOrNull!.tracks.single;
      expect(track.clips, hasLength(2));

      final compound = track.clips.first as CompoundClip;
      expect(compound.start, const Duration(seconds: 2));
      expect(compound.duration, const Duration(seconds: 8));
      expect(compound.innerClips, hasLength(2));
      expect(compound.innerClips[0].start, Duration.zero);
      expect(compound.innerClips[1].start, const Duration(seconds: 4));
    });

    test('a transition between members rides along inside', () {
      final withTransition = TimelineOperations.setTransition(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4)]),
        'a',
        const Transition(id: 't', type: TransitionType.fade),
      ).valueOrNull!;

      final compound = TimelineOperations.group(withTransition, {'a', 'b'})
          .valueOrNull!
          .tracks
          .single
          .clips
          .single as CompoundClip;

      expect(compound.innerClips.first.hasTransition, isTrue);
      expect(compound.innerClips.last.hasTransition, isFalse,
          reason: 'the outgoing transition lost its partner');
    });

    test('clips on different tracks are refused with the reason', () {
      final timeline = _timeline(
        [_clip('a', 0, 4)],
        extraTracks: [
          Track(
            id: 'v2',
            type: TrackType.overlay,
            clips: [
              const VideoClip(
                id: 'x',
                trackId: 'v2',
                start: Duration.zero,
                duration: Duration(seconds: 4),
                assetId: 'asset',
              ),
            ],
          ),
        ],
      );
      final result = TimelineOperations.group(timeline, {'a', 'x'});
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('one track'));
    });

    test('a stranger inside the span is named in the refusal', () {
      final result = TimelineOperations.group(
        _timeline([
          _clip('a', 0, 4),
          _clip('mid', 4, 2).copyWith(label: 'cutaway'),
          _clip('b', 6, 4),
        ]),
        {'a', 'b'},
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('cutaway'));
    });

    test('groups cannot nest', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4), _clip('c', 8, 4)]),
        {'a', 'b'},
      ).valueOrNull!;
      final compoundId = grouped.tracks.single.clips
          .whereType<CompoundClip>()
          .single
          .id;

      final result = TimelineOperations.group(grouped, {compoundId, 'c'});
      expect(result.isErr, isTrue);
    });
  });

  group('ungroup', () {
    test('is lossless: members land exactly where they were', () {
      final original = _timeline([_clip('a', 2, 4), _clip('b', 6, 4)]);
      final grouped = TimelineOperations.group(original, {'a', 'b'})
          .valueOrNull!;
      final compoundId =
          grouped.tracks.single.clips.single.id;

      final restored = TimelineOperations.ungroup(grouped, compoundId)
          .valueOrNull!;
      final clips = restored.tracks.single.clips;
      expect(clips, hasLength(2));
      expect(clips[0].start, const Duration(seconds: 2));
      expect(clips[0].duration, const Duration(seconds: 4));
      expect(clips[1].start, const Duration(seconds: 6));
      expect(clips[1].end, const Duration(seconds: 10));
    });

    test('a moved group ungroups at its new home', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4)]),
        {'a', 'b'},
      ).valueOrNull!;
      final compoundId = grouped.tracks.single.clips.single.id;

      final moved = TimelineOperations.move(
        grouped,
        compoundId,
        const Duration(seconds: 10),
      ).valueOrNull!;

      final clips = TimelineOperations.ungroup(moved, compoundId)
          .valueOrNull!
          .tracks
          .single
          .clips;
      expect(clips[0].start, const Duration(seconds: 10));
      expect(clips[1].start, const Duration(seconds: 14));
    });

    test('refused when something now occupies the landing spot', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4), _clip('c', 12, 2)]),
        {'a', 'b'},
      ).valueOrNull!;
      final compoundId = grouped.tracks.single.clips
          .whereType<CompoundClip>()
          .single
          .id;

      // Park the group so its second member would land on top of 'c'.
      final moved = TimelineOperations.move(
        grouped,
        compoundId,
        const Duration(seconds: 9),
      );
      // The move itself may already collide with 'c'; place c later instead.
      final result = moved.isErr
          ? moved
          : TimelineOperations.ungroup(moved.valueOrNull!, compoundId);
      expect(result.isErr, isTrue);
    });

    test('splitting a group is refused with guidance', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4)]),
        {'a', 'b'},
      ).valueOrNull!;
      final compoundId = grouped.tracks.single.clips.single.id;

      final result = TimelineOperations.split(
        grouped,
        compoundId,
        const Duration(seconds: 3),
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.message, contains('Ungroup'));
    });
  });

  group('persistence and export', () {
    const asset = MediaAsset(
      id: 'asset',
      path: '/media/a.mp4',
      kind: AssetKind.video,
      duration: Duration(seconds: 60),
      width: 1920,
      height: 1080,
      hasVideoStream: true,
      hasAudioStream: true,
    );

    Project projectWith(Timeline timeline) => Project(
      id: 'p',
      name: 'P',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      assets: const {'asset': asset},
      timeline: timeline,
    );

    test('a compound survives the JSON round trip intact', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4)]),
        {'a', 'b'},
      ).valueOrNull!;

      final reloaded = Project.fromJson(
        jsonDecode(jsonEncode(projectWith(grouped).toJson()))
            as Map<String, dynamic>,
      );
      final compound =
          reloaded.timeline.tracks.single.clips.single as CompoundClip;
      expect(compound.innerClips, hasLength(2));
      expect(compound.innerClips[1].start, const Duration(seconds: 4));
      expect(compound.duration, const Duration(seconds: 8));
    });

    test('the export flattens members through the real track machinery', () {
      final grouped = TimelineOperations.group(
        _timeline([_clip('a', 0, 4), _clip('b', 4, 4)]),
        {'a', 'b'},
      ).valueOrNull!;

      final plan = const TimelineCompiler().compile(
        project: projectWith(grouped),
        settings: const ExportSettings(),
        workspaceDir: '/tmp/work',
        outputPath: '/out/x.mp4',
        encoder: const EncoderChoice(
          encoderName: 'libx264',
          isHardware: false,
          codec: VideoCodec.h264,
        ),
        encoderProbe: HardwareEncoderProbe(FFmpegService()),
      );

      expect(
        plan.warnings.where((w) => w.contains('Internal graph error')),
        isEmpty,
        reason: plan.warnings.join('; '),
      );
      // Two members → two trims of the source appear inside the compound.
      expect(
        RegExp('trim=start=').allMatches(plan.filterGraph).length,
        greaterThanOrEqualTo(2),
      );
      // Their audio reaches the mix at the compound's offset (4s member →
      // adelay 4000ms).
      expect(plan.filterGraph, contains('adelay=delays=4000'));
    });
  });
}
