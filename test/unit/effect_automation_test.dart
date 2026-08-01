/// Keyframed effects must animate on export, not freeze at their t=0 value.
///
/// The generated script format is additionally verified against a real ffmpeg
/// binary in `tool/verify_sendcmd.sh`, which is what proved the `filter@label`
/// target syntax rather than assuming it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/effect.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/engine/effects/effect_catalog.dart';
import 'package:procut_studio/engine/export/effect_automation.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _asset = MediaAsset(
  id: 'ast_v',
  path: '/media/clip.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 30),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
);

/// A blur ramping 0 → 30 over the clip.
Effect _animatedBlur({String id = 'fx1'}) => Effect(
  id: id,
  type: EffectType.blur,
  params: {
    'radius': const AnimatableDouble(0).withKeyframe(
      const Keyframe(time: Duration.zero, value: 0, easing: Easing.linear),
    ).withKeyframe(
      const Keyframe(
        time: Duration(seconds: 4),
        value: 30,
        easing: Easing.linear,
      ),
    ),
  },
);

VideoClip _clip(List<Effect> effects, {Duration? duration}) => VideoClip(
  id: 'c1',
  trackId: 'trk_v',
  start: Duration.zero,
  duration: duration ?? const Duration(seconds: 4),
  assetId: 'ast_v',
  effects: effects,
);

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

RenderPlan _compileWith(VideoClip clip) {
  final project = Project(
    id: 'prj',
    name: 'Test',
    createdAt: _epoch,
    updatedAt: _epoch,
    assets: const {'ast_v': _asset},
    timeline: Timeline(
      fps: 30,
      width: 1080,
      height: 1920,
      tracks: [
        Track(id: 'trk_v', type: TrackType.video, clips: [clip]),
      ],
    ),
  );
  return const TimelineCompiler().compile(
    project: project,
    settings: const ExportSettings(),
    workspaceDir: '/tmp/work',
    outputPath: '/out/render.mp4',
    encoder: const EncoderChoice(
      encoderName: 'libx264',
      isHardware: false,
      codec: VideoCodec.h264,
    ),
    encoderProbe: HardwareEncoderProbe(FFmpegService()),
  );
}

void main() {
  group('script generation', () {
    test('a static effect produces no automation at all', () {
      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([
          const Effect(
            id: 'fx1',
            type: EffectType.blur,
            params: {'radius': AnimatableDouble.constant(8)},
          ),
        ]),
        scriptPath: '/tmp/fx.cmd',
      );

      expect(automation.hasScript, isFalse);
      expect(automation.staticEffectTypes, isEmpty);
    });

    test('an animated effect produces a sampled script', () {
      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([_animatedBlur()]),
        scriptPath: '/tmp/fx.cmd',
      );

      expect(automation.hasScript, isTrue);
      final script = automation.script!;
      expect(script.path, '/tmp/fx.cmd');
      // 4s at 10 Hz.
      expect(script.commandCount, greaterThan(30));
    });

    test('commands target filter@label, the syntax ffmpeg expects', () {
      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([_animatedBlur()]),
        scriptPath: '/tmp/fx.cmd',
      );

      final first = automation.script!.contents.split('\n').first;
      // e.g. "0.000 gblur@fxfx1 sigma 0;"
      expect(
        first,
        matches(RegExp(r'^\d+\.\d{3} gblur@\w+ sigma [\d.-]+;$')),
        reason: 'target must be filter@label, not label@filter',
      );
    });

    test('the value genuinely ramps across the script', () {
      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([_animatedBlur()]),
        scriptPath: '/tmp/fx.cmd',
      );

      final values = automation.script!.contents
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .map((l) => double.parse(l.split(' ').last.replaceAll(';', '')))
          .toList();

      expect(values.first, closeTo(0, 0.01));
      // radius 30 -> sigma 10.
      expect(values.last, closeTo(10, 0.5));
      // Monotonically increasing for a linear ramp.
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i - 1]));
      }
    });

    test('an unchanging parameter is not re-sent every sample', () {
      // Intensity animates; 'radius' is constant. Only sigma is bound, and it
      // does change (intensity scales it), so assert the dedupe on a genuinely
      // flat curve instead.
      final flat = Effect(
        id: 'fx1',
        type: EffectType.blur,
        params: {
          'radius': const AnimatableDouble(9)
              .withKeyframe(const Keyframe(time: Duration.zero, value: 9))
              .withKeyframe(
                const Keyframe(time: Duration(seconds: 4), value: 9),
              ),
        },
      );

      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([flat]),
        scriptPath: '/tmp/fx.cmd',
      );

      // One command sets it; the rest are suppressed as no-ops.
      expect(automation.script!.commandCount, 1);
    });

    test('an effect whose filter cannot take commands is reported', () {
      final animatedSharpen = Effect(
        id: 'fx1',
        type: EffectType.sharpen, // unsharp has no command support
        params: {
          'amount': const AnimatableDouble(0)
              .withKeyframe(const Keyframe(time: Duration.zero, value: 0.2))
              .withKeyframe(
                const Keyframe(time: Duration(seconds: 4), value: 1.5),
              ),
        },
      );

      final automation = EffectAutomationCompiler.compile(
        fps: 30,
        clip: _clip([animatedSharpen]),
        scriptPath: '/tmp/fx.cmd',
      );

      expect(automation.hasScript, isFalse);
      expect(automation.staticEffectTypes, contains(EffectType.sharpen));
    });
  });

  group('representative resolution', () {
    test('an effect ramping up from zero still emits a filter instance', () {
      // The regression this guards: building at t=0 gives radius 0, the
      // emitter correctly returns no filters, and the effect vanishes from the
      // render with nothing for sendcmd to drive.
      final resolved = EffectAutomationCompiler.representativeResolution(
        _animatedBlur(),
        const Duration(seconds: 4),
      );

      expect(resolved.value('radius'), greaterThan(0));
      expect(
        EffectCatalog.specFor(EffectType.blur)!.buildFilters(resolved),
        isNotEmpty,
      );
    });

    test('a static effect resolves at zero, unchanged', () {
      const effect = Effect(
        id: 'fx1',
        type: EffectType.blur,
        params: {'radius': AnimatableDouble.constant(8)},
      );

      final resolved = EffectAutomationCompiler.representativeResolution(
        effect,
        const Duration(seconds: 4),
      );

      expect(resolved.value('radius'), 8);
    });
  });

  group('compiler integration', () {
    test('the graph gains a sendcmd and a labelled filter instance', () {
      final plan = _compileWith(_clip([_animatedBlur()]));

      expect(plan.filterGraph, contains('sendcmd'));
      expect(
        plan.filterGraph,
        matches(RegExp(r'gblur@\w+')),
        reason: 'the instance must be labelled or commands cannot address it',
      );
      expect(plan.commandScripts, hasLength(1));
    });

    test('sendcmd precedes the filter it drives', () {
      final plan = _compileWith(_clip([_animatedBlur()]));
      final graph = plan.filterGraph;

      expect(
        graph.indexOf('sendcmd'),
        lessThan(graph.indexOf('gblur@')),
        reason: 'sendcmd only reaches filters downstream of it',
      );
    });

    test('a static effect produces neither sendcmd nor a script', () {
      final plan = _compileWith(
        _clip([
          const Effect(
            id: 'fx1',
            type: EffectType.blur,
            params: {'radius': AnimatableDouble.constant(8)},
          ),
        ]),
      );

      expect(plan.filterGraph, isNot(contains('sendcmd')));
      expect(plan.commandScripts, isEmpty);
      expect(plan.filterGraph, contains('gblur'));
      expect(plan.filterGraph, isNot(matches(RegExp(r'gblur@'))));
    });

    test('an un-animatable effect surfaces an export warning', () {
      final plan = _compileWith(
        _clip([
          Effect(
            id: 'fx1',
            type: EffectType.sharpen,
            params: {
              'amount': const AnimatableDouble(0)
                  .withKeyframe(const Keyframe(time: Duration.zero, value: 0.2))
                  .withKeyframe(
                    const Keyframe(time: Duration(seconds: 4), value: 1.5),
                  ),
            },
          ),
        ]),
      );

      expect(
        plan.warnings.join(),
        contains('first-frame value'),
        reason: 'the user must be told before waiting out the render',
      );
    });

    test('the script path lands inside the render workspace', () {
      final plan = _compileWith(_clip([_animatedBlur()]));

      expect(plan.commandScripts.single.path, startsWith('/tmp/work'));
      expect(plan.commandScripts.single.path, endsWith('.cmd'));
    });
  });

  group('catalogue integrity', () {
    test('every command binding names a filter its emitter actually produces', () {
      // Guards the silent failure mode: a binding targeting `gblur` on an
      // effect that emits `boxblur` would label nothing and drive nothing.
      for (final spec in EffectCatalog.all) {
        if (spec.commands.isEmpty) continue;

        final probe = ResolvedEffect(
          type: spec.type,
          intensity: 1,
          values: {
            for (final p in spec.params) p.key: p.max,
          },
          strings: const {'lut': '/tmp/x.cube', 'key': '0x00FF00'},
        );
        final emitted = spec.buildFilters(probe).map((f) => f.name).toSet();

        for (final binding in spec.commands) {
          expect(
            emitted,
            contains(binding.filter),
            reason:
                '${spec.label}: binding targets "${binding.filter}" but the '
                'emitter produces ${emitted.join(', ')}',
          );
        }
      }
    });

    test('bound values agree with the static path at a constant value', () {
      // An animated effect sitting at a constant value must render identically
      // to a non-animated one, or toggling keyframes would shift the picture.
      final spec = EffectCatalog.specFor(EffectType.blur)!;
      const probe = ResolvedEffect(
        type: EffectType.blur,
        intensity: 1,
        values: {'radius': 12},
      );

      final staticSigma = double.parse(
        spec.buildFilters(probe).single.params['sigma']! as String,
      );
      final commandSigma = spec.commands.single.valueAt(probe);

      expect(commandSigma, closeTo(staticSigma, 0.001));
    });
  });
}
