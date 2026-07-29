/// Project persistence is JSON, so a round-trip test is the whole safety net
/// for the storage layer. Anything that survives here survives a save/load.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/constants/app_constants.dart';
import 'package:procut_studio/data/datasources/local/project_migrations.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/text_style_spec.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/domain/entities/transition.dart';

Project _richProject() {
  final asset = MediaAsset(
    id: 'ast_1',
    path: '/storage/emulated/0/DCIM/clip.mp4',
    kind: AssetKind.video,
    duration: const Duration(seconds: 30),
    width: 1920,
    height: 1080,
    fps: 29.97,
    rotationDegrees: 90,
    hasAudioStream: true,
    hasVideoStream: true,
    displayName: 'clip',
  );

  return Project(
    id: 'prj_1',
    name: 'Round trip',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000100000),
    assets: {asset.id: asset},
    timeline: Timeline(
      fps: 30,
      width: 1080,
      height: 1920,
      tracks: [
        Track(
          id: 'trk_v',
          type: TrackType.video,
          clips: [
            VideoClip(
              id: 'clip_1',
              trackId: 'trk_v',
              start: Duration.zero,
              duration: const Duration(seconds: 6),
              assetId: 'ast_1',
              sourceIn: const Duration(seconds: 2),
              speed: 1.5,
              reversed: true,
              volume: const AnimatableDouble(1).withKeyframe(
                const Keyframe(time: Duration(seconds: 1), value: 0.2),
              ),
              audioFadeIn: const Duration(milliseconds: 300),
              transform: Transform2D.identity.copyWith(
                crop: const CropRect(left: 0.1, right: 0.1),
                flipHorizontal: true,
                blendMode: LayerBlendMode.screen,
                rotation: const AnimatableDouble(0).withKeyframe(
                  const Keyframe(
                    time: Duration(seconds: 2),
                    value: 45,
                    easing: Easing.back,
                  ),
                ),
              ),
              effects: [
                Effect(
                  id: 'fx_1',
                  type: EffectType.vhs,
                  params: {'amount': const AnimatableDouble.constant(0.8)},
                ),
                const Effect(
                  id: 'fx_2',
                  type: EffectType.cinematicLut,
                  stringParams: {'lut': 'assets/luts/teal_orange.cube'},
                ),
              ],
              outTransition: const Transition(
                id: 'trn_1',
                type: TransitionType.glitch,
                duration: Duration(milliseconds: 450),
                intensity: 0.8,
              ),
            ),
            VideoClip(
              id: 'clip_2',
              trackId: 'trk_v',
              start: const Duration(seconds: 6),
              duration: const Duration(seconds: 4),
              assetId: 'ast_1',
              freezeFrameAt: const Duration(seconds: 3),
              muted: true,
            ),
          ],
        ),
        const Track(
          id: 'trk_t',
          type: TrackType.text,
          clips: [
            TextClip(
              id: 'clip_txt',
              trackId: 'trk_t',
              start: Duration(seconds: 1),
              duration: Duration(seconds: 3),
              text: 'Hello: world, "quoted" \\ escaped',
              style: TextStyleSpec(
                fontFamily: 'Bebas Neue',
                gradientColors: [0xFF7C5CFF, 0xFF00E5C0],
                strokeWidth: 0.06,
                glowRadius: 0.2,
                allCaps: true,
              ),
              animationIn: TextAnimation.typewriter,
            ),
          ],
        ),
        Track(
          id: 'trk_a',
          type: TrackType.audio,
          clips: [
            AudioClip(
              id: 'clip_aud',
              trackId: 'trk_a',
              start: Duration.zero,
              duration: const Duration(seconds: 10),
              assetId: 'ast_1',
              pitchSemitones: -3,
              equalizer: const EqualizerSettings(bass: 4, treble: -2),
              isVoiceOver: true,
            ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  group('project round-trip', () {
    test('survives encode → decode with every field intact', () {
      final original = _richProject();
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.timeline.fps, 30);
      expect(restored.timeline.tracks, hasLength(3));
      expect(restored.assets['ast_1']!.rotationDegrees, 90);
      expect(restored.duration, original.duration);
    });

    test('preserves clip subtype and its specific fields', () {
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(_richProject().toJson()))
            as Map<String, dynamic>,
      );

      final video = restored.timeline.findClip('clip_1')!.$2;
      expect(video, isA<VideoClip>());
      video as VideoClip;
      expect(video.speed, 1.5);
      expect(video.reversed, isTrue);
      expect(video.sourceIn, const Duration(seconds: 2));
      expect(video.audioFadeIn, const Duration(milliseconds: 300));
      expect(video.transform.flipHorizontal, isTrue);
      expect(video.transform.crop.left, 0.1);
      expect(video.transform.blendMode, LayerBlendMode.screen);

      final frozen = restored.timeline.findClip('clip_2')!.$2 as VideoClip;
      expect(frozen.isFrozen, isTrue);
      expect(frozen.freezeFrameAt, const Duration(seconds: 3));
      expect(frozen.muted, isTrue);

      final audio = restored.timeline.findClip('clip_aud')!.$2 as AudioClip;
      expect(audio.pitchSemitones, -3);
      expect(audio.equalizer.bass, 4);
      expect(audio.isVoiceOver, isTrue);
    });

    test('preserves keyframes on transform and volume', () {
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(_richProject().toJson()))
            as Map<String, dynamic>,
      );

      final video = restored.timeline.findClip('clip_1')!.$2 as VideoClip;
      expect(video.transform.rotation.keyframes, hasLength(1));
      expect(video.transform.rotation.keyframes.single.easing, Easing.back);
      expect(video.volume.keyframes.single.value, 0.2);
    });

    test('preserves effects including their string parameters', () {
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(_richProject().toJson()))
            as Map<String, dynamic>,
      );

      final video = restored.timeline.findClip('clip_1')!.$2;
      expect(video.effects, hasLength(2));
      expect(video.effects[0].type, EffectType.vhs);
      expect(video.effects[0].param('amount'), 0.8);
      expect(
        video.effects[1].stringParams['lut'],
        'assets/luts/teal_orange.cube',
      );
    });

    test('preserves text content with characters that need escaping', () {
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(_richProject().toJson()))
            as Map<String, dynamic>,
      );

      final text = restored.timeline.findClip('clip_txt')!.$2 as TextClip;
      expect(text.text, 'Hello: world, "quoted" \\ escaped');
      expect(text.style.gradientColors, [0xFF7C5CFF, 0xFF00E5C0]);
      expect(text.style.allCaps, isTrue);
      expect(text.animationIn, TextAnimation.typewriter);
    });

    test('preserves the transition on the outgoing clip', () {
      final restored = Project.fromJson(
        jsonDecode(jsonEncode(_richProject().toJson()))
            as Map<String, dynamic>,
      );

      final transition =
          restored.timeline.findClip('clip_1')!.$2.outTransition!;
      expect(transition.type, TransitionType.glitch);
      expect(transition.duration, const Duration(milliseconds: 450));
      expect(transition.intensity, 0.8);
    });

    test('ProjectSummary reads a project without materialising the timeline', () {
      final json = _richProject().toJson();
      final summary = ProjectSummary.fromJson(json);

      expect(summary.id, 'prj_1');
      expect(summary.clipCount, 4);
      expect(summary.duration, const Duration(seconds: 10));
    });

    test('pruneAssets drops media no clip references', () {
      final project = _richProject().withAsset(
        const MediaAsset(
          id: 'ast_orphan',
          path: '/tmp/unused.mp4',
          kind: AssetKind.video,
          duration: Duration(seconds: 5),
        ),
      );

      expect(project.assets, hasLength(2));
      expect(project.pruneAssets().assets, hasLength(1));
    });
  });

  group('migrations', () {
    test('v1 millisecond fields become microseconds', () {
      final v1 = <String, dynamic>{
        'schema': 1,
        'id': 'prj_old',
        'name': 'Legacy',
        'createdAt': 0,
        'updatedAt': 0,
        'timeline': {
          'fps': 30,
          'tracks': [
            {
              'id': 'trk_1',
              'type': 'video',
              'clips': [
                {
                  'id': 'clip_1',
                  'trackId': 'trk_1',
                  'kind': 'video',
                  'assetId': 'ast_1',
                  'start': 1000,
                  'duration': 5000,
                  'sourceIn': 250,
                },
              ],
            },
          ],
        },
      };

      final migrated = ProjectMigrations.migrate(v1);
      expect(migrated.isOk, isTrue);

      final project = Project.fromJson(migrated.unwrap());
      final clip = project.timeline.tracks.single.clips.single as VideoClip;

      expect(clip.start, const Duration(seconds: 1));
      expect(clip.duration, const Duration(seconds: 5));
      expect(clip.sourceIn, const Duration(milliseconds: 250));
      expect(project.schemaVersion, AppConstants.projectSchemaVersion);
    });

    test('v2 track-level transitions move onto the outgoing clip', () {
      final v2 = <String, dynamic>{
        'schema': 2,
        'id': 'prj_old',
        'name': 'Legacy',
        'createdAt': 0,
        'updatedAt': 0,
        'timeline': {
          'fps': 30,
          'tracks': [
            {
              'id': 'trk_1',
              'type': 'video',
              'clips': [
                {
                  'id': 'clip_1',
                  'trackId': 'trk_1',
                  'kind': 'video',
                  'assetId': 'ast_1',
                  'startUs': 0,
                  'durUs': 5000000,
                },
              ],
              'transitions': [
                {
                  'id': 'trn_1',
                  'type': 'fade',
                  'durUs': 500000,
                  'fromClipId': 'clip_1',
                },
              ],
            },
          ],
        },
      };

      final project = Project.fromJson(ProjectMigrations.migrate(v2).unwrap());
      final clip = project.timeline.tracks.single.clips.single;

      expect(clip.outTransition, isNotNull);
      expect(clip.outTransition!.type, TransitionType.fade);
      expect(clip.outTransition!.duration, const Duration(milliseconds: 500));
    });

    test('a newer schema is refused rather than mangled', () {
      final future = <String, dynamic>{
        'schema': AppConstants.projectSchemaVersion + 5,
        'id': 'prj_future',
        'name': 'From the future',
      };

      final result = ProjectMigrations.migrate(future);
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.code, 'project_corrupt');
    });

    test('a current-schema project passes through untouched', () {
      final current = _richProject().toJson();
      final result = ProjectMigrations.migrate(current);

      expect(result.isOk, isTrue);
      expect(result.unwrap()['schema'], AppConstants.projectSchemaVersion);
    });
  });
}
