/// Covers the features added on top of the original build: masks, speed
/// ramping, markers, paste, adjustment layers, export presets and templates.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/export_preset.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/marker.dart';
import 'package:procut_studio/domain/entities/mask.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/project_template.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/usecases/timeline_operations.dart';
import 'package:procut_studio/engine/effects/mask_compiler.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';
import 'package:procut_studio/engine/timeline/timeline_view_state.dart';

const _asset = MediaAsset(
  id: 'ast_v',
  path: '/media/clip.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
);

VideoClip _video({
  String id = 'c1',
  Duration start = Duration.zero,
  Duration duration = const Duration(seconds: 10),
  AnimatableDouble? speedCurve,
  Mask mask = Mask.none,
  List<Effect> effects = const [],
}) => VideoClip(
  id: id,
  trackId: 'trk_v',
  start: start,
  duration: duration,
  assetId: 'ast_v',
  speedCurve: speedCurve,
  mask: mask,
  effects: effects,
);

Timeline _timeline(List<Clip> clips, {List<Track>? tracks}) => Timeline(
  fps: 30,
  width: 1080,
  height: 1920,
  tracks: tracks ?? [Track(id: 'trk_v', type: TrackType.video, clips: clips)],
);

Project _project(Timeline timeline) => Project(
  id: 'prj',
  name: 'Test',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  assets: const {'ast_v': _asset},
  timeline: timeline,
);

void main() {
  group('speed ramping', () {
    test('a constant curve consumes the same source as a plain speed', () {
      final ramped = _video(
        speedCurve: const AnimatableDouble(2)
            .withKeyframe(const Keyframe(time: Duration.zero, value: 2))
            .withKeyframe(const Keyframe(time: Duration(seconds: 10), value: 2)),
      );

      // 10s of timeline at a constant 2x consumes 20s of source.
      expect(
        ramped.sourceDuration.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 50),
      );
    });

    test('a ramp consumes the integral, not the endpoint rate', () {
      // Linear 1x → 3x over 10s. Mean rate 2x, so ~20s of source.
      final ramped = _video(
        speedCurve: const AnimatableDouble(1)
            .withKeyframe(
              const Keyframe(time: Duration.zero, value: 1, easing: Easing.linear),
            )
            .withKeyframe(
              const Keyframe(
                time: Duration(seconds: 10),
                value: 3,
                easing: Easing.linear,
              ),
            ),
      );

      expect(
        ramped.sourceDuration.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 200),
        reason: 'the mean of a linear 1→3 ramp is 2',
      );
    });

    test('source time advances monotonically through a ramp', () {
      final ramped = _video(
        speedCurve: const AnimatableDouble(1)
            .withKeyframe(
              const Keyframe(time: Duration.zero, value: 0.5, easing: Easing.linear),
            )
            .withKeyframe(
              const Keyframe(
                time: Duration(seconds: 10),
                value: 4,
                easing: Easing.linear,
              ),
            ),
      );

      var previous = Duration.zero;
      for (var i = 0; i <= 20; i++) {
        final at = Duration(milliseconds: i * 500);
        final source = ramped.sourceTimeAt(at);
        expect(
          source,
          greaterThanOrEqualTo(previous),
          reason: 'source time went backwards — audio would desync',
        );
        previous = source;
      }
    });

    test('setSpeedCurve re-times the clip and ripples the next one', () {
      final timeline = _timeline([
        _video(duration: const Duration(seconds: 10)),
        _video(
          id: 'c2',
          start: const Duration(seconds: 10),
          duration: const Duration(seconds: 5),
        ),
      ]);

      // A constant 2x curve should behave like setSpeed(2): 10s → 5s.
      final curve = const AnimatableDouble(2)
          .withKeyframe(const Keyframe(time: Duration.zero, value: 2))
          .withKeyframe(const Keyframe(time: Duration(seconds: 10), value: 2));

      final result = TimelineOperations.setSpeedCurve(timeline, 'c1', curve);
      final clips = result.unwrap().tracks.single.clips;

      expect(clips[0].duration.inSeconds, closeTo(5, 1));
      expect(clips[1].start, clips[0].end);
    });

    test('clearing a ramp restores constant timing', () {
      final timeline = _timeline([
        _video(
          speedCurve: const AnimatableDouble(2)
              .withKeyframe(const Keyframe(time: Duration.zero, value: 2))
              .withKeyframe(
                const Keyframe(time: Duration(seconds: 10), value: 2),
              ),
        ),
      ]);

      final result = TimelineOperations.setSpeedCurve(timeline, 'c1', null);
      final clip = result.unwrap().tracks.single.clips.single as VideoClip;

      expect(clip.hasSpeedRamp, isFalse);
      expect(clip.speedCurve, isNull);
    });

    test('a ramp survives serialisation', () {
      final project = _project(
        _timeline([
          _video(
            speedCurve: const AnimatableDouble(1).withKeyframe(
              const Keyframe(time: Duration(seconds: 2), value: 0.4),
            ),
          ),
        ]),
      );

      final restored = Project.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      final clip = restored.timeline.findClip('c1')!.$2 as VideoClip;

      expect(clip.speedCurve, isNotNull);
      expect(clip.speedCurve!.keyframes.single.value, 0.4);
    });
  });

  group('masking', () {
    test('an inactive mask emits no filters', () {
      expect(MaskCompiler.build(Mask.none.resolveAt(Duration.zero)), isEmpty);
    });

    test('an ellipse mask writes the alpha plane', () {
      const mask = Mask(shape: MaskShape.ellipse);
      final filters = MaskCompiler.build(mask.resolveAt(Duration.zero));

      expect(filters.map((f) => f.name), contains('geq'));
      final geq = filters.firstWhere((f) => f.name == 'geq');
      expect(geq.params['a'], isNotNull);
      expect(geq.params['a'].toString(), contains('sqrt'));
    });

    test('a rectangle mask uses a Chebyshev distance', () {
      const mask = Mask(shape: MaskShape.rectangle);
      final geq = MaskCompiler.build(mask.resolveAt(Duration.zero))
          .firstWhere((f) => f.name == 'geq');

      expect(geq.params['a'].toString(), contains('max('));
    });

    test('inverting flips the expression', () {
      const normal = Mask(shape: MaskShape.ellipse);
      const inverted = Mask(shape: MaskShape.ellipse, inverted: true);

      final a = MaskCompiler.build(normal.resolveAt(Duration.zero))
          .firstWhere((f) => f.name == 'geq')
          .params['a']
          .toString();
      final b = MaskCompiler.build(inverted.resolveAt(Duration.zero))
          .firstWhere((f) => f.name == 'geq')
          .params['a']
          .toString();

      expect(a, isNot(b));
      expect(b, startsWith('255*(1-'));
    });

    test('an alpha plane is created before it is written', () {
      const mask = Mask(shape: MaskShape.ellipse);
      final filters = MaskCompiler.build(mask.resolveAt(Duration.zero));

      // yuva420p must come first, or geq has no alpha channel to set.
      expect(filters.first.name, 'format');
      expect(filters.first.params['pix_fmts'], 'yuva420p');
    });

    test('a mask survives a split, shifted onto the new clock', () {
      final mask = Mask(
        shape: MaskShape.ellipse,
        centerX: const AnimatableDouble(0.5).withKeyframe(
          const Keyframe(time: Duration(seconds: 6), value: 0.9),
        ),
      );
      final timeline = _timeline([_video(mask: mask)]);

      final result = TimelineOperations.split(
        timeline,
        'c1',
        const Duration(seconds: 4),
      );
      final right = result.unwrap().tracks.single.clips[1];

      expect(right.mask.shape, MaskShape.ellipse);
      expect(
        right.mask.centerX.keyframes.single.time,
        const Duration(seconds: 2),
      );
    });

    test('a mask round-trips through JSON', () {
      final project = _project(
        _timeline([
          _video(
            mask: const Mask(
              shape: MaskShape.linear,
              inverted: true,
              feather: AnimatableDouble.constant(0.2),
            ),
          ),
        ]),
      );

      final restored = Project.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      final mask = restored.timeline.findClip('c1')!.$2.mask;

      expect(mask.shape, MaskShape.linear);
      expect(mask.inverted, isTrue);
      expect(mask.feather.staticValue, 0.2);
    });
  });

  group('markers', () {
    test('a marker is added at the frame grid', () {
      final result = TimelineOperations.addMarker(
        _timeline([]),
        const Duration(milliseconds: 1010),
        label: 'Intro',
      );
      final marker = result.unwrap().markers.single;

      expect(marker.label, 'Intro');
      expect(marker.time.inMilliseconds, closeTo(1000, 34));
    });

    test('a duplicate at the same frame and kind is ignored', () {
      var timeline = _timeline([]);
      timeline = TimelineOperations.addMarker(
        timeline,
        const Duration(seconds: 1),
      ).unwrap();
      timeline = TimelineOperations.addMarker(
        timeline,
        const Duration(seconds: 1),
      ).unwrap();

      expect(timeline.markers, hasLength(1));
    });

    test('beat markers replace previous beats but keep notes', () {
      var timeline = TimelineOperations.addMarker(
        _timeline([]),
        const Duration(seconds: 1),
        label: 'keep me',
      ).unwrap();

      timeline = TimelineOperations.setBeatMarkers(timeline, [
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      ]).unwrap();
      timeline = TimelineOperations.setBeatMarkers(timeline, [
        const Duration(seconds: 4),
      ]).unwrap();

      expect(timeline.markers.where((m) => m.kind == MarkerKind.beat), hasLength(1));
      expect(timeline.markers.where((m) => m.label == 'keep me'), hasLength(1));
    });

    test('beat markers are excluded from the chapter list', () {
      var timeline = TimelineOperations.addMarker(
        _timeline([]),
        const Duration(seconds: 1),
        kind: MarkerKind.chapter,
      ).unwrap();
      timeline = TimelineOperations.setBeatMarkers(timeline, [
        const Duration(seconds: 2),
      ]).unwrap();

      expect(timeline.chapterMarkers, hasLength(1));
      expect(timeline.markers, hasLength(2));
    });

    test('markers become edit points and snap targets', () {
      final timeline = TimelineOperations.addMarker(
        _timeline([_video()]),
        const Duration(seconds: 7),
      ).unwrap();

      expect(timeline.editPoints, contains(const Duration(seconds: 7)));

      const view = TimelineViewState(pixelsPerSecond: 60);
      final snap = view.snap(const Duration(milliseconds: 7040), timeline);
      expect(snap.target, SnapTarget.marker);
    });

    test('markers survive serialisation', () {
      final project = _project(
        TimelineOperations.addMarker(
          _timeline([]),
          const Duration(seconds: 3),
          label: 'Chorus',
          kind: MarkerKind.chapter,
        ).unwrap(),
      );

      final restored = Project.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );

      expect(restored.timeline.markers.single.label, 'Chorus');
      expect(restored.timeline.markers.single.kind, MarkerKind.chapter);
    });
  });

  group('paste', () {
    test('preserves the relative spacing of copied clips', () {
      final source = _timeline([
        _video(id: 'a', duration: const Duration(seconds: 2)),
        _video(
          id: 'b',
          start: const Duration(seconds: 5),
          duration: const Duration(seconds: 2),
        ),
      ]);
      final copied = source.tracks.single.clips;

      final target = _timeline([]);
      final result = TimelineOperations.paste(
        target,
        copied,
        const Duration(seconds: 10),
      );
      final clips = result.unwrap().tracks.single.clips;

      expect(clips, hasLength(2));
      expect(clips[0].start, const Duration(seconds: 10));
      // The copies start 5s apart, so they stay 5s apart after pasting.
      expect(clips[1].start, const Duration(seconds: 15));
    });

    test('pasted clips get fresh ids', () {
      final source = _timeline([_video(id: 'a')]);
      final result = TimelineOperations.paste(
        _timeline([]),
        source.tracks.single.clips,
        Duration.zero,
      );

      expect(result.unwrap().tracks.single.clips.single.id, isNot('a'));
    });

    test('pasting nothing is a no-op', () {
      final timeline = _timeline([_video()]);
      final result = TimelineOperations.paste(timeline, const [], Duration.zero);
      expect(result.unwrap().clipCount, 1);
    });
  });

  group('adjustment layers', () {
    test('an adjustment track applies to the composite, gated by time', () {
      final timeline = Timeline(
        fps: 30,
        width: 1080,
        height: 1920,
        tracks: [
          Track(id: 'trk_v', type: TrackType.video, clips: [_video()]),
          Track(
            id: 'trk_adj',
            type: TrackType.adjustment,
            clips: [
              ImageClip(
                id: 'adj1',
                trackId: 'trk_adj',
                start: const Duration(seconds: 2),
                duration: const Duration(seconds: 3),
                assetId: '',
                effects: [
                  Effect(
                    id: 'fx',
                    type: EffectType.colorAdjust,
                    params: {
                      'saturation': const AnimatableDouble.constant(1.8),
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      final plan = const TimelineCompiler().compile(
        project: _project(timeline),
        settings: const ExportSettings(),
        workspaceDir: '/tmp/w',
        outputPath: '/out/o.mp4',
        encoder: const EncoderChoice(
          encoderName: 'libx264',
          isHardware: false,
          codec: VideoCodec.h264,
        ),
        encoderProbe: HardwareEncoderProbe(FFmpegService()),
      );

      expect(plan.filterGraph, contains('enable='));
      // Commas separate filters, so the gate's arguments are escaped. Assert on
      // the parts rather than the literal, or this breaks the moment escaping
      // changes — which would be a false alarm, not a regression.
      expect(plan.filterGraph, contains('between(t'));
      expect(plan.filterGraph, contains('2.000'));
      expect(plan.filterGraph, contains('5.000'));
    });

    test('an adjustment track is not composited as a picture layer', () {
      final adjustmentOnly = Timeline(
        fps: 30,
        width: 1080,
        height: 1920,
        tracks: [
          Track(id: 'trk_v', type: TrackType.video, clips: [_video()]),
          const Track(id: 'trk_adj', type: TrackType.adjustment),
        ],
      );

      final plan = const TimelineCompiler().compile(
        project: _project(adjustmentOnly),
        settings: const ExportSettings(),
        workspaceDir: '/tmp/w',
        outputPath: '/out/o.mp4',
        encoder: const EncoderChoice(
          encoderName: 'libx264',
          isHardware: false,
          codec: VideoCodec.h264,
        ),
        encoderProbe: HardwareEncoderProbe(FFmpegService()),
      );

      expect(plan.warnings, isEmpty);
    });
  });

  group('stabilisation', () {
    test('lifts into two pre-render passes, detect before transform', () {
      final timeline = _timeline([
        _video(
          effects: [const Effect(id: 'fx', type: EffectType.stabilise)],
        ),
      ]);

      final plan = const TimelineCompiler().compile(
        project: _project(timeline),
        settings: const ExportSettings(),
        workspaceDir: '/tmp/w',
        outputPath: '/out/o.mp4',
        encoder: const EncoderChoice(
          encoderName: 'libx264',
          isHardware: false,
          codec: VideoCodec.h264,
        ),
        encoderProbe: HardwareEncoderProbe(FFmpegService()),
      );

      expect(plan.preRenderSteps, hasLength(2));
      expect(plan.preRenderSteps[0].command, contains('vidstabdetect'));
      expect(plan.preRenderSteps[1].command, contains('vidstabtransform'));
      // The transform must read the file the detect pass wrote.
      expect(plan.preRenderSteps[1].command, contains('.trf'));
      // And the main pass must read the stabilised output, not the original.
      expect(plan.inputs.any((i) => i.path.contains('stab_')), isTrue);
    });
  });

  group('export presets', () {
    test('every preset produces valid settings', () {
      for (final preset in ExportPreset.all) {
        expect(
          preset.settings.validate(),
          isEmpty,
          reason: '${preset.name} has invalid settings',
        );
      }
    });

    test('matches recognises a canvas of the right shape', () {
      const vertical = Timeline(width: 1080, height: 1920);
      const horizontal = Timeline(width: 1920, height: 1080);

      final reels = ExportPreset.byId('reels')!;
      expect(reels.matches(vertical), isTrue);
      expect(reels.matches(horizontal), isFalse);
    });

    test('platform duration limits are enforced', () {
      final reels = ExportPreset.byId('reels')!;
      expect(reels.exceedsLimit(const Duration(seconds: 80)), isFalse);
      expect(reels.exceedsLimit(const Duration(minutes: 2)), isTrue);
    });

    test('the master preset keeps the project resolution', () {
      expect(
        ExportPreset.byId('master')!.settings.resolution,
        ExportResolution.source,
      );
    });
  });

  group('templates', () {
    ProjectTemplate buildTemplate() {
      final project = _project(
        _timeline([
          _video(id: 'a', duration: const Duration(seconds: 4)),
          _video(
            id: 'b',
            start: const Duration(seconds: 4),
            duration: const Duration(seconds: 6),
          ),
        ]),
      );
      return ProjectTemplate.fromProject(project, name: 'Two shots');
    }

    test('captures one slot per media clip', () {
      final template = buildTemplate();
      expect(template.slotCount, 2);
      expect(template.slots.first.duration, const Duration(seconds: 4));
    });

    test('applying fills slots and keeps the template timing', () {
      const long = MediaAsset(
        id: 'x',
        path: '/m/x.mp4',
        kind: AssetKind.video,
        duration: Duration(seconds: 30),
      );
      const long2 = MediaAsset(
        id: 'y',
        path: '/m/y.mp4',
        kind: AssetKind.video,
        duration: Duration(seconds: 30),
      );

      final applied = buildTemplate().apply(
        projectName: 'From template',
        assets: const [long, long2],
      );

      expect(applied.filledSlots, 2);
      expect(applied.isComplete, isTrue);

      final clips = applied.project.timeline.tracks.single.clips;
      // The template's rhythm survives: 4s then 6s, not the assets' 30s.
      expect(clips[0].duration, const Duration(seconds: 4));
      expect(clips[1].duration, const Duration(seconds: 6));
    });

    test('a too-short asset is reported rather than silently absorbed', () {
      const short = MediaAsset(
        id: 'x',
        path: '/m/x.mp4',
        kind: AssetKind.video,
        duration: Duration(seconds: 2),
      );
      const ok = MediaAsset(
        id: 'y',
        path: '/m/y.mp4',
        kind: AssetKind.video,
        duration: Duration(seconds: 30),
      );

      final applied = buildTemplate().apply(
        projectName: 'From template',
        assets: const [short, ok],
      );

      expect(applied.shortfalls, hasLength(1));
      expect(applied.shortfalls.single, contains('slot needs'));
      expect(applied.isComplete, isFalse);
    });

    test('unfilled slots are removed rather than left as black holes', () {
      const only = MediaAsset(
        id: 'x',
        path: '/m/x.mp4',
        kind: AssetKind.video,
        duration: Duration(seconds: 30),
      );

      final applied = buildTemplate().apply(
        projectName: 'From template',
        assets: const [only],
      );

      expect(applied.filledSlots, 1);
      expect(applied.unfilledSlots, 1);
      expect(applied.project.timeline.clipCount, 1);
    });

    test('a template round-trips through JSON', () {
      final template = buildTemplate();
      final restored = ProjectTemplate.fromJson(
        jsonDecode(jsonEncode(template.toJson())) as Map<String, dynamic>,
      );

      expect(restored.name, template.name);
      expect(restored.slotCount, template.slotCount);
      expect(restored.duration, template.duration);
    });
  });
}
