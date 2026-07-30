/// The whole chain, one test file: build a project the way a user would,
/// edit it with the real operations, survive a save/load round trip, and
/// compile a render plan whose graph holds together.
///
/// Each stage feeds the next — a bug anywhere in the chain fails here even if
/// every unit test around it passes, because unit tests hand-build their
/// inputs and this does not. This is as close to "run the app" as a test can
/// get without a device.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/error/result.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/ducking.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transition.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/effects/effect_catalog.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _fps = 30;

const _footage = MediaAsset(
  id: 'footage',
  path: '/media/footage.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: true,
);

const _broll = MediaAsset(
  id: 'broll',
  path: '/media/broll.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 40),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: false,
);

const _music = MediaAsset(
  id: 'music',
  path: '/media/music.mp3',
  kind: AssetKind.audio,
  duration: Duration(seconds: 120),
  hasAudioStream: true,
);

const _still = MediaAsset(
  id: 'still',
  path: '/media/photo.jpg',
  kind: AssetKind.image,
  duration: Duration.zero,
  width: 3000,
  height: 2000,
);

/// Unwraps an edit that must succeed, failing the test with the reason if it
/// does not — so a broken stage reports *which* edit died, not a null error.
Timeline _must(Result<Timeline> result, String what) {
  final timeline = result.valueOrNull;
  expect(
    timeline,
    isNotNull,
    reason: '$what failed: ${result.failureOrNull?.message}',
  );
  return timeline!;
}

void main() {
  test('a real edit survives the whole pipeline', () {
    // ── 1. Assemble the project the way the editor controller would ────
    var timeline = const Timeline(
      fps: _fps,
      width: 1080,
      height: 1920,
      tracks: [
        Track(id: 'v1', type: TrackType.video),
        Track(id: 'music', type: TrackType.audio, name: 'Music'),
      ],
    );

    timeline = _must(
      TimelineOperations.insertClip(
        timeline,
        'v1',
        const VideoClip(
          id: 'main',
          trackId: 'v1',
          start: Duration.zero,
          duration: Duration(seconds: 20),
          assetId: 'footage',
        ),
      ),
      'insert main footage',
    );
    timeline = _must(
      TimelineOperations.insertClip(
        timeline,
        'v1',
        const VideoClip(
          id: 'broll1',
          trackId: 'v1',
          start: Duration(seconds: 20),
          duration: Duration(seconds: 8),
          assetId: 'broll',
        ),
      ),
      'insert b-roll',
    );
    timeline = _must(
      TimelineOperations.insertClip(
        timeline,
        'v1',
        const ImageClip(
          id: 'photo',
          trackId: 'v1',
          start: Duration(seconds: 28),
          duration: Duration(seconds: 4),
          assetId: 'still',
        ),
      ),
      'insert still',
    );
    timeline = _must(
      TimelineOperations.insertClip(
        timeline,
        'music',
        const AudioClip(
          id: 'song',
          trackId: 'music',
          start: Duration.zero,
          duration: Duration(seconds: 32),
          assetId: 'music',
        ),
      ),
      'insert music',
    );

    // ── 2. Edit with the real vocabulary ───────────────────────────────
    timeline = _must(
      TimelineOperations.split(timeline, 'main', const Duration(seconds: 8)),
      'split the main clip',
    );
    final rightHalf = timeline
        .tracks
        .firstWhere((t) => t.id == 'v1')
        .clipAt(const Duration(seconds: 10))!;

    timeline = _must(
      TimelineOperations.setSpeed(timeline, rightHalf.id, 2.0),
      'speed up the second half',
    );
    timeline = _must(
      TimelineOperations.slip(
        timeline,
        'broll1',
        const Duration(seconds: 2),
        sourceLimit: _broll.duration,
      ),
      'slip the b-roll',
    );
    timeline = _must(
      TimelineOperations.kenBurns(timeline, 'photo', zoom: 0.2),
      'Ken Burns on the still',
    );
    timeline = _must(
      TimelineOperations.addEffect(
        timeline,
        'main',
        EffectCatalog.specFor(EffectType.filmGrain)!.instantiate('fx1'),
      ),
      'add film grain',
    );
    timeline = _must(
      TimelineOperations.setTransition(
        timeline,
        'main',
        const Transition(
          id: 'tr1',
          type: TransitionType.fade,
          duration: Duration(milliseconds: 500),
        ),
      ),
      'add a transition',
    );

    // The music ducks under the footage's embedded voice.
    timeline = timeline.replaceTrack(
      timeline.tracks
          .firstWhere((t) => t.id == 'music')
          .copyWith(ducking: const Ducking(keyTrackId: 'v1')),
    );

    // Cut pattern sanity after all of that.
    expect(timeline.clipCount, 5);
    expect(timeline.duration, const Duration(seconds: 32));

    var project = Project(
      id: 'itest',
      name: 'Integration cut',
      createdAt: DateTime(2026, 7, 30),
      updatedAt: DateTime(2026, 7, 30),
      assets: const {
        'footage': _footage,
        'broll': _broll,
        'music': _music,
        'still': _still,
      },
      timeline: timeline,
    );

    // ── 3. Survive persistence ─────────────────────────────────────────
    // The repository stores exactly this JSON string; if anything in the new
    // feature set forgot its serialisation, the reloaded edit diverges here.
    final reloaded = Project.fromJson(
      jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
    );
    expect(reloaded.timeline.clipCount, project.timeline.clipCount);
    expect(reloaded.timeline.duration, project.timeline.duration);
    expect(
      reloaded.timeline.tracks
          .firstWhere((t) => t.id == 'music')
          .ducking
          ?.keyTrackId,
      'v1',
      reason: 'ducking must survive the save/load round trip',
    );
    final reloadedPhoto = reloaded.timeline.findClip('photo')!.$2;
    expect(
      reloadedPhoto.transform.isAnimated,
      isTrue,
      reason: 'Ken Burns keyframes must survive the round trip',
    );
    final reloadedRight = reloaded.timeline.findClip(rightHalf.id)!.$2;
    expect((reloadedRight as MediaClip).speed, 2.0);
    project = reloaded;

    // ── 4. Compile the export ──────────────────────────────────────────
    final plan = const TimelineCompiler().compile(
      project: project,
      settings: const ExportSettings(),
      workspaceDir: '/tmp/work',
      outputPath: '/out/final.mp4',
      encoder: const EncoderChoice(
        encoderName: 'libx264',
        isHardware: false,
        codec: VideoCodec.h264,
      ),
      encoderProbe: HardwareEncoderProbe(FFmpegService()),
    );

    // No internal graph errors surfaced as warnings.
    expect(
      plan.warnings.where((w) => w.contains('Internal graph error')),
      isEmpty,
      reason: plan.warnings.join('; '),
    );

    final graph = plan.filterGraph;
    expect(graph, contains('xfade'), reason: 'the transition must render');
    expect(graph, contains('zoompan'),
        reason: 'the still\'s camera move must actually render');
    expect(graph, contains('sidechaincompress'),
        reason: 'the duck must reach the mixer');
    expect(graph, contains('setpts'), reason: 'the speed change must render');
    expect(plan.videoOutLabel, isNotNull);
    expect(plan.audioOutLabel, isNotNull);

    // Every input the graph consumes is an input the plan actually opens.
    final padRefs = RegExp(r'\[(\d+):[va]\]')
        .allMatches(graph)
        .map((m) => int.parse(m.group(1)!))
        .toSet();
    for (final index in padRefs) {
      expect(index, lessThan(plan.inputs.length),
          reason: 'graph consumes input $index the plan never opens');
    }

    // The command assembles without a device.
    final command = plan.buildCommand();
    expect(command, contains('-filter_complex'));
    expect(command, contains('/out/final.mp4'));
  });

  test('an empty project refuses to compile into nonsense', () {
    final empty = Project(
      id: 'empty',
      name: 'Empty',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      assets: const {},
      timeline: const Timeline(fps: _fps, tracks: []),
    );

    final plan = const TimelineCompiler().compile(
      project: empty,
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

    // A bare colour source is fine; a crash or a graph with dangling labels
    // is not. The plan must stay internally consistent even with nothing in
    // it.
    expect(
      plan.warnings.where((w) => w.contains('Internal graph error')),
      isEmpty,
    );
  });
}
