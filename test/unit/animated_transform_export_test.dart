/// Keyframes that the preview honours and the export used to freeze.
///
/// Opacity, rotation and mask parameters are all animatable, the keyframe
/// editor offers all three, and the preview resolves all three per frame. The
/// export read `.staticValue` (or sampled the mask at t=0), so a fade built
/// from opacity keyframes rendered at one fixed opacity and an animated mask
/// never moved. These tests pin the fix.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/mask.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _asset = MediaAsset(
  id: 'a',
  path: '/media/a.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: false,
);

/// Two keyframes from [from] to [to] over five seconds.
AnimatableDouble _ramp(double from, double to) => AnimatableDouble(
  from,
  keyframes: [
    Keyframe(time: Duration.zero, value: from),
    Keyframe(time: const Duration(seconds: 5), value: to),
  ],
);

RenderPlan _compile(Clip clip) => const TimelineCompiler().compile(
  project: Project(
    id: 'p',
    name: 'Animated',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    assets: const {'a': _asset},
    timeline: Timeline(
      fps: 30,
      width: 1080,
      height: 1920,
      tracks: [
        Track(id: 'v1', type: TrackType.video, clips: [clip]),
      ],
    ),
  ),
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

VideoClip _clip({Transform2D? transform, Mask? mask}) => VideoClip(
  id: 'c',
  trackId: 'v1',
  start: Duration.zero,
  duration: const Duration(seconds: 5),
  assetId: 'a',
  transform: transform ?? Transform2D.identity,
  mask: mask ?? Mask.none,
);

/// The whole of every generated sendcmd script, concatenated.
String _scripts(RenderPlan plan) =>
    plan.commandScripts.map((s) => s.contents).join('\n');

void main() {
  group('opacity', () {
    test('a fade built from keyframes animates on export', () {
      final plan = _compile(
        _clip(
          transform: Transform2D.identity.copyWith(opacity: _ramp(0, 1)),
        ),
      );

      // colorchannelmixer takes runtime commands, so the existing sendcmd
      // machinery drives it — the alternative was one frozen opacity.
      expect(plan.filterGraph, contains('colorchannelmixer'));
      expect(plan.filterGraph, contains('sendcmd'));

      final script = _scripts(plan);
      expect(script, contains('colorchannelmixer@'));
      expect(script, contains('aa'));
      // Starts transparent and reaches opaque.
      expect(script, matches(RegExp(r'aa 0(\.0+)?\b')));
      expect(script, matches(RegExp(r'aa (1|0\.9\d+)')));
    });

    test('a static opacity still takes the cheap path', () {
      final plan = _compile(
        _clip(
          transform: Transform2D.identity.copyWith(
            opacity: const AnimatableDouble(0.5),
          ),
        ),
      );
      expect(plan.filterGraph, contains('colorchannelmixer'));
      expect(_scripts(plan), isNot(contains('colorchannelmixer@')));
    });

    test('a fully opaque layer emits nothing at all', () {
      final plan = _compile(_clip());
      expect(plan.filterGraph, isNot(contains('colorchannelmixer')));
    });
  });

  group('rotation', () {
    test('animated rotation drives the rotate filter', () {
      final plan = _compile(
        _clip(
          transform: Transform2D.identity.copyWith(rotation: _ramp(0, 45)),
        ),
      );

      expect(plan.filterGraph, contains('rotate'));
      final script = _scripts(plan);
      expect(script, contains('rotate@'));
      expect(script, contains('angle'));
    });

    test('a static right angle still uses the cheap transpose', () {
      final plan = _compile(
        _clip(
          transform: Transform2D.identity.copyWith(
            rotation: const AnimatableDouble(90),
          ),
        ),
      );
      expect(plan.filterGraph, contains('transpose'));
      expect(_scripts(plan), isNot(contains('rotate@')));
    });
  });

  group('mask', () {
    test('an animated mask moves with time', () {
      final plan = _compile(
        _clip(
          mask: Mask(
            shape: MaskShape.ellipse,
            centerX: _ramp(0.2, 0.8),
            centerY: const AnimatableDouble.constant(0.5),
            width: const AnimatableDouble.constant(0.3),
            height: const AnimatableDouble.constant(0.3),
          ),
        ),
      );

      // geq takes no runtime commands, but it does expose T — so the
      // animation lives in the expression itself.
      expect(plan.filterGraph, contains('geq'));
      expect(
        plan.filterGraph,
        contains('T'),
        reason: 'a mask sampled once at t=0 never moves',
      );
      // Both endpoints must appear in the interpolation.
      expect(plan.filterGraph, contains('0.2'));
      expect(plan.filterGraph, contains('0.8'));
    });

    test('a static mask stays a plain constant expression', () {
      final plan = _compile(
        _clip(
          mask: const Mask(
            shape: MaskShape.rectangle,
            centerX: AnimatableDouble.constant(0.5),
            centerY: AnimatableDouble.constant(0.5),
            width: AnimatableDouble.constant(0.25),
            height: AnimatableDouble.constant(0.25),
          ),
        ),
      );

      expect(plan.filterGraph, contains('geq'));
      // No time term: a constant mask must not pay for an interpolation it
      // does not need, on every pixel of every frame.
      expect(
        RegExp(r'\bT\b').hasMatch(plan.filterGraph),
        isFalse,
      );
    });

    test('no mask emits no geq', () {
      expect(_compile(_clip()).filterGraph, isNot(contains('geq')));
    });
  });
}
