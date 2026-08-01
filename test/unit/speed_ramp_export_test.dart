/// Speed ramps, as they reach the export.
///
/// The preview honours a ramp, the timeline's duration maths honours it, and
/// the export rendered one constant speed — while a comment in the compiler
/// described the segmenting it was not doing and a warning told the user
/// about stepping that could not occur. A silent gap is bad; a documented
/// one that is not there is worse.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _asset = MediaAsset(
  id: 'a',
  path: '/media/a.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 120),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: true,
);

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// A clip that starts at normal speed and ends at 4×.
VideoClip _ramped() => VideoClip(
  id: 'c',
  trackId: 'v1',
  start: Duration.zero,
  duration: const Duration(seconds: 8),
  assetId: 'a',
  speed: 2,
  speedCurve: const AnimatableDouble(
    1,
    keyframes: [
      Keyframe(time: Duration.zero, value: 1),
      Keyframe(time: Duration(seconds: 8), value: 4),
    ],
  ),
);

VideoClip _constant() => const VideoClip(
  id: 'c',
  trackId: 'v1',
  start: Duration.zero,
  duration: Duration(seconds: 8),
  assetId: 'a',
  speed: 2,
);

RenderPlan _compile(Clip clip) => const TimelineCompiler().compile(
  project: Project(
    id: 'p',
    name: 'Ramp',
    createdAt: _epoch,
    updatedAt: _epoch,
    assets: const {'a': _asset},
    timeline: const Timeline(fps: 30, width: 1080, height: 1920, tracks: []),
  ).copyWith(
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

void main() {
  group('video', () {
    test('a ramp emits many rates, not one', () {
      final graph = _compile(_ramped()).filterGraph;
      final rates = RegExp(r'setpts=[\d.]+\*PTS').allMatches(graph).length;
      expect(
        rates,
        greaterThan(4),
        reason: 'a ramp rendered as a single setpts is not a ramp',
      );
    });

    test('the rates actually change across the clip', () {
      final graph = _compile(_ramped()).filterGraph;
      final values = RegExp(r'setpts=([\d.]+)\*PTS')
          .allMatches(graph)
          .map((m) => double.parse(m.group(1)!))
          .toList();

      // The multiplier is 1/rate, so accelerating means it shrinks.
      expect(values.first, greaterThan(values.last));
      expect(values.toSet().length, greaterThan(3),
          reason: 'distinct rates, not the same number repeated');
    });

    test('the segments are concatenated back into one stream', () {
      expect(_compile(_ramped()).filterGraph, contains('concat=n='));
    });

    test('a constant speed still takes the cheap single-filter path', () {
      final graph = _compile(_constant()).filterGraph;
      expect(RegExp(r'setpts=[\d.]+\*PTS').allMatches(graph).length, 1);
      expect(graph, isNot(contains('concat=n=')));
    });

    test('the warning no longer describes something that does not happen', () {
      final plan = _compile(_ramped());
      // If a warning mentions stepping, stepping must be real.
      for (final warning in plan.warnings) {
        if (warning.toLowerCase().contains('step')) {
          expect(plan.filterGraph, contains('concat=n='));
        }
      }
    });

    test('the graph stays wirable', () {
      final plan = _compile(_ramped());
      expect(
        plan.warnings.where((w) => w.contains('Internal graph error')),
        isEmpty,
        reason: plan.warnings.join('; '),
      );
    });
  });

  group('audio', () {
    test('a ramped clip’s sound follows the same curve', () {
      final graph = _compile(_ramped()).filterGraph;
      // Picture speeding up while sound plays at one rate is a drift, and it
      // grows across the clip until they are visibly apart.
      final tempos = RegExp(r'atempo=[\d.]+').allMatches(graph).length;
      expect(
        tempos,
        greaterThan(2),
        reason: 'the mix must be re-timed segment by segment too',
      );
      expect(graph, contains('concat=n='));
    });

    test('a constant speed keeps the simple atempo path', () {
      final graph = _compile(_constant()).filterGraph;
      expect(graph, contains('atempo'));
      expect(
        RegExp(r'atrim=[^,;]*,asetpts[^,;]*,atempo').allMatches(graph).length,
        lessThanOrEqualTo(1),
      );
    });
  });
}
