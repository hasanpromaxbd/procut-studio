/// The compiler is pure, so the generated FFmpeg graph can be asserted on
/// directly — no device, no encoder, no media files.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/text_style_spec.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/domain/entities/transition.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/filter_graph.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _videoAsset = MediaAsset(
  id: 'ast_v',
  path: '/media/clip.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 30),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: true,
);

const _musicAsset = MediaAsset(
  id: 'ast_m',
  path: '/media/music.mp3',
  kind: AssetKind.audio,
  duration: Duration(seconds: 60),
  hasAudioStream: true,
);

Project _project(List<Track> tracks, {Map<String, MediaAsset>? assets}) => Project(
  id: 'prj',
  name: 'Test',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  assets: assets ?? {'ast_v': _videoAsset, 'ast_m': _musicAsset},
  timeline: Timeline(fps: 30, width: 1080, height: 1920, tracks: tracks),
);

RenderPlan _compile(
  Project project, {
  ExportSettings settings = const ExportSettings(),
  bool hardware = false,
}) {
  final probe = HardwareEncoderProbe(FFmpegService());
  return const TimelineCompiler().compile(
    project: project,
    settings: settings,
    workspaceDir: '/tmp/work',
    outputPath: '/out/render.mp4',
    encoder: EncoderChoice(
      encoderName: hardware ? 'h264_mediacodec' : 'libx264',
      isHardware: hardware,
      codec: VideoCodec.h264,
    ),
    encoderProbe: probe,
  );
}

void main() {
  group('graph structure', () {
    test('a single video clip produces a valid, self-consistent graph', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );

      // Every consumed pad label must be produced somewhere.
      expect(plan.warnings, isEmpty);
      expect(plan.filterGraph, contains('trim'));
      expect(plan.filterGraph, contains('overlay'));
      expect(plan.videoOutLabel, isNotNull);
      expect(plan.inputs, hasLength(1));
      expect(plan.inputs.single.path, '/media/clip.mp4');
    });

    test('deduplicates inputs when clips share a source file', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
              const VideoClip(
                id: 'c2',
                trackId: 'trk_v',
                start: Duration(seconds: 5),
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                sourceIn: Duration(seconds: 10),
              ),
            ],
          ),
        ]),
      );

      // One `-i` for the file even though two clips use it.
      final videoInputs =
          plan.inputs.where((i) => i.path == '/media/clip.mp4').length;
      expect(videoInputs, 1);
    });

    test('emits a concat for a plain cut and an xfade for a transition', () {
      final plain = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
              const VideoClip(
                id: 'c2',
                trackId: 'trk_v',
                start: Duration(seconds: 5),
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );
      expect(plain.filterGraph, contains('concat'));
      expect(plain.filterGraph, isNot(contains('xfade')));

      final withTransition = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                outTransition: Transition(
                  id: 't1',
                  type: TransitionType.fade,
                  duration: Duration(milliseconds: 600),
                ),
              ),
              const VideoClip(
                id: 'c2',
                trackId: 'trk_v',
                start: Duration(milliseconds: 4400),
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );
      expect(withTransition.filterGraph, contains('xfade'));
      expect(withTransition.filterGraph, contains('transition=fade'));
    });

    test('a non-native transition compiles to a custom expression', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                outTransition: Transition(
                  id: 't1',
                  type: TransitionType.ripple,
                  duration: Duration(milliseconds: 600),
                ),
              ),
              const VideoClip(
                id: 'c2',
                trackId: 'trk_v',
                start: Duration(milliseconds: 4400),
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );

      expect(plan.filterGraph, contains('transition=custom'));
      expect(plan.filterGraph, contains('expr='));
      // And the user is warned it will be slow.
      expect(plan.warnings.join(), contains('slow'));
    });

    test('fills gaps between clips with a transparent source', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration(seconds: 2),
                duration: Duration(seconds: 3),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );

      // Base canvas plus the leading gap.
      expect('color='.allMatches(plan.filterGraph).length, greaterThanOrEqualTo(2));
    });
  });

  group('clip properties', () {
    test('speed emits setpts with the reciprocal factor', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                speed: 2.0,
              ),
            ],
          ),
        ]),
      );

      expect(plan.filterGraph, contains('setpts=0.5*PTS'));
    });

    test('a reversed clip becomes a pre-render pass, not an inline filter', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                reversed: true,
              ),
            ],
          ),
        ]),
      );

      expect(plan.preRenderSteps, hasLength(1));
      expect(plan.preRenderSteps.single.command, contains('reverse'));
      // The main pass reads the pre-rendered file instead.
      expect(plan.inputs.any((i) => i.path.contains('reversed_')), isTrue);
    });

    test('a freeze frame emits loop rather than a normal trim', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 2),
                assetId: 'ast_v',
                freezeFrameAt: Duration(seconds: 4),
              ),
            ],
          ),
        ]),
      );

      expect(plan.filterGraph, contains('loop='));
    });

    test('crop and flip appear before the fit-to-canvas scale', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: const Duration(seconds: 5),
                assetId: 'ast_v',
                transform: Transform2D.identity.copyWith(
                  crop: const CropRect(left: 0.1, right: 0.1),
                  flipHorizontal: true,
                ),
              ),
            ],
          ),
        ]),
      );

      final graph = plan.filterGraph;
      expect(graph, contains('crop='));
      expect(graph, contains('hflip'));
      expect(
        graph.indexOf('crop='),
        lessThan(graph.indexOf('force_original_aspect_ratio')),
        reason: 'cropping after a fit would cut the wrong region',
      );
    });

    test('container rotation is applied explicitly', () {
      final rotated = _videoAsset.copyWith(rotationDegrees: 90);
      final plan = _compile(
        _project(
          [
            Track(
              id: 'trk_v',
              type: TrackType.video,
              clips: [
                const VideoClip(
                  id: 'c1',
                  trackId: 'trk_v',
                  start: Duration.zero,
                  duration: Duration(seconds: 5),
                  assetId: 'ast_v',
                ),
              ],
            ),
          ],
          assets: {'ast_v': rotated},
        ),
      );

      expect(plan.filterGraph, contains('transpose'));
    });

    test('an effect contributes its FFmpeg filter', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: const Duration(seconds: 5),
                assetId: 'ast_v',
                effects: [
                  Effect(
                    id: 'fx',
                    type: EffectType.blur,
                    params: {'radius': const AnimatableDouble.constant(12)},
                  ),
                ],
              ),
            ],
          ),
        ]),
      );

      expect(plan.filterGraph, contains('gblur'));
    });
  });

  group('audio', () {
    test('mixes video audio and a music track with normalize disabled', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
          Track(
            id: 'trk_a',
            type: TrackType.audio,
            clips: [
              const AudioClip(
                id: 'a1',
                trackId: 'trk_a',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_m',
              ),
            ],
          ),
        ]),
      );

      expect(plan.audioOutLabel, isNotNull);
      expect(plan.filterGraph, contains('amix'));
      expect(
        plan.filterGraph,
        contains('normalize=0'),
        reason: 'amix normalisation makes every added track quieter',
      );
    });

    test('a muted video clip contributes no audio', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
                muted: true,
              ),
            ],
          ),
        ]),
      );

      expect(plan.audioOutLabel, isNull);
      expect(plan.outputArgs, contains('-an'));
    });

    test('a muted track is excluded from the mix', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_a',
            type: TrackType.audio,
            muted: true,
            clips: [
              const AudioClip(
                id: 'a1',
                trackId: 'trk_a',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_m',
              ),
            ],
          ),
        ]),
      );

      expect(plan.audioOutLabel, isNull);
    });

    test('a delayed audio clip is positioned with adelay', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_a',
            type: TrackType.audio,
            clips: [
              const AudioClip(
                id: 'a1',
                trackId: 'trk_a',
                start: Duration(seconds: 3),
                duration: Duration(seconds: 5),
                assetId: 'ast_m',
              ),
            ],
          ),
        ]),
      );

      expect(plan.filterGraph, contains('adelay'));
      expect(plan.filterGraph, contains('delays=3000'));
    });

    test('a large speed change decomposes atempo into a cascade', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_a',
            type: TrackType.audio,
            clips: [
              const AudioClip(
                id: 'a1',
                trackId: 'trk_a',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_m',
                speed: 4.0,
              ),
            ],
          ),
        ]),
      );

      // atempo only accepts 0.5–2.0 per instance, so 4x must be 2.0 twice.
      expect('atempo'.allMatches(plan.filterGraph).length, greaterThanOrEqualTo(2));
    });
  });

  group('output settings', () {
    test('portrait projects keep their orientation at every resolution', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
        settings: const ExportSettings(resolution: ExportResolution.p1080),
      );

      expect(plan.width, 1080);
      expect(plan.height, 1920);
    });

    test('dimensions are always even, as the encoders require', () {
      const settings = ExportSettings(resolution: ExportResolution.p720);
      final (w, h) = settings.dimensionsFor(1080, 1921);

      expect(w.isEven, isTrue);
      expect(h.isEven, isTrue);
    });

    test('software encoding uses CRF; hardware uses a bitrate target', () {
      final project = _project([
        Track(
          id: 'trk_v',
          type: TrackType.video,
          clips: [
            const VideoClip(
              id: 'c1',
              trackId: 'trk_v',
              start: Duration.zero,
              duration: Duration(seconds: 5),
              assetId: 'ast_v',
            ),
          ],
        ),
      ]);

      expect(_compile(project).outputArgs, contains('-crf'));
      expect(_compile(project, hardware: true).outputArgs, contains('-b:v'));
    });

    test('HEVC is tagged hvc1 so QuickTime and iOS can play it', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
        settings: const ExportSettings(videoCodec: VideoCodec.hevc),
      );

      expect(plan.outputArgs, containsAllInOrder(['-tag:v', 'hvc1']));
    });

    test('faststart is always set so the file streams while downloading', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );

      expect(plan.outputArgs, containsAllInOrder(['-movflags', '+faststart']));
    });

    test('the assembled command has filter_complex and maps in order', () {
      final plan = _compile(
        _project([
          Track(
            id: 'trk_v',
            type: TrackType.video,
            clips: [
              const VideoClip(
                id: 'c1',
                trackId: 'trk_v',
                start: Duration.zero,
                duration: Duration(seconds: 5),
                assetId: 'ast_v',
              ),
            ],
          ),
        ]),
      );

      final command = plan.buildCommand();
      expect(command, startsWith('-y -hide_banner'));
      expect(command, contains('-filter_complex'));
      expect(command, contains('-map'));
      expect(command.indexOf('-filter_complex'), lessThan(command.indexOf('-map')));
    });
  });

  group('text layers', () {
    test('a static title becomes one PNG raster step', () {
      final plan = _compile(
        _project([
          const Track(
            id: 'trk_t',
            type: TrackType.text,
            clips: [
              TextClip(
                id: 't1',
                trackId: 'trk_t',
                start: Duration.zero,
                duration: Duration(seconds: 3),
                text: 'Hello',
              ),
            ],
          ),
        ]),
      );

      expect(plan.rasterSteps, hasLength(1));
      expect(plan.rasterSteps.single.isSequence, isFalse);
      expect(plan.rasterSteps.single.frameCount, 1);
    });

    test('an animated title becomes a PNG sequence at project fps', () {
      final plan = _compile(
        _project([
          const Track(
            id: 'trk_t',
            type: TrackType.text,
            clips: [
              TextClip(
                id: 't1',
                trackId: 'trk_t',
                start: Duration.zero,
                duration: Duration(seconds: 2),
                text: 'Hello',
                animationIn: TextAnimation.typewriter,
              ),
            ],
          ),
        ]),
      );

      final step = plan.rasterSteps.single;
      expect(step.isSequence, isTrue);
      expect(step.frameCount, 60); // 2s at 30fps
      expect(plan.inputs.any((i) => i.path.contains('%05d.png')), isTrue);
    });
  });

  group('filter graph escaping', () {
    test('a value with a colon is quoted', () {
      expect(FilterGraph.escapeValue('a:b'), contains(r'\:'));
    });

    test('a plain value is left alone', () {
      expect(FilterGraph.escapeValue('simple'), 'simple');
    });

    test('a path with a colon is escaped for filter use', () {
      expect(
        FilterGraph.escapePath('/sdcard/Trip: Nepal/clip.mp4'),
        r'/sdcard/Trip\: Nepal/clip.mp4',
      );
    });

    test('opaque and translucent colours format correctly', () {
      expect(FilterGraph.colorFrom(0xFF00FF00), '0x00ff00');
      expect(FilterGraph.colorFrom(0x80FF0000), startsWith('0xff0000@'));
    });

    test('floats are trimmed to something readable', () {
      expect(FilterGraph.formatDouble(2.0), '2');
      expect(FilterGraph.formatDouble(0.5), '0.5');
      expect(FilterGraph.formatDouble(1 / 3), '0.333333');
    });

    test('validate spots an unresolved label', () {
      final graph = FilterGraph();
      graph.chain(inputs: ['missing'], outputs: ['out']).then(Filter('null'));

      expect(graph.validate(), contains('missing'));
    });

    test('validate accepts file-input pads', () {
      final graph = FilterGraph();
      graph.chain(inputs: ['0:v'], outputs: ['out']).then(Filter('null'));

      expect(graph.validate(), isEmpty);
    });
  });
}
