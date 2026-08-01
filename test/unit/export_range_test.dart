/// Rendering a window of the timeline instead of all of it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_range.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
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

RenderPlan _compile({ExportRange? range}) =>
    const TimelineCompiler().compile(
      project: Project(
        id: 'p',
        name: 'Range',
        createdAt: _epoch,
        updatedAt: _epoch,
        assets: const {'a': _asset},
        timeline: const Timeline(
          fps: 30,
          width: 1080,
          height: 1920,
          tracks: [
            Track(
              id: 'v1',
              type: TrackType.video,
              clips: [
                VideoClip(
                  id: 'c',
                  trackId: 'v1',
                  start: Duration.zero,
                  duration: Duration(seconds: 60),
                  assetId: 'a',
                ),
              ],
            ),
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
      range: range,
    );

void main() {
  group('ExportRange', () {
    test('clamps to the timeline', () {
      const range = ExportRange(
        start: Duration(seconds: -5),
        end: Duration(seconds: 500),
      );
      // A window covering everything is not a window — null keeps the graph
      // free of a trim that would only cost time.
      expect(range.clampedTo(const Duration(seconds: 60)), isNull);
    });

    test('a window past the end is trimmed, not rejected', () {
      const range = ExportRange(
        start: Duration(seconds: 50),
        end: Duration(seconds: 500),
      );
      final clamped = range.clampedTo(const Duration(seconds: 60))!;
      expect(clamped.end, const Duration(seconds: 60));
      expect(clamped.duration, const Duration(seconds: 10));
    });

    test('a window entirely past the end is nothing', () {
      const range = ExportRange(
        start: Duration(seconds: 90),
        end: Duration(seconds: 100),
      );
      expect(range.clampedTo(const Duration(seconds: 60)), isNull);
    });

    test('around() builds a window at a point', () {
      final range = ExportRange.around(
        const Duration(seconds: 30),
        length: const Duration(seconds: 10),
      );
      expect(range.start, const Duration(seconds: 30));
      expect(range.end, const Duration(seconds: 40));
    });

    test('around() never starts before zero', () {
      final range = ExportRange.around(
        const Duration(seconds: -5),
        length: const Duration(seconds: 10),
      );
      expect(range.start, Duration.zero);
    });
  });

  group('compiling a range', () {
    test('trims both picture and sound to the same window', () {
      final plan = _compile(
        range: const ExportRange(
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
      );

      // Trimming only one of the two is the classic way to ship a drifting
      // export, so both must appear.
      expect(plan.filterGraph, contains('trim=start=10:end=20'));
      expect(plan.filterGraph, contains('atrim=start=10:end=20'));
      expect(plan.duration, const Duration(seconds: 10));
    });

    test('the clip itself is compiled exactly as for a full render', () {
      final full = _compile().filterGraph;
      final ranged = _compile(
        range: const ExportRange(
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
      ).filterGraph;

      // The whole point: a range export is a window onto the real render, not
      // a different, shorter edit. The clip's own segment must be identical.
      final segment = RegExp(r'\[0:v\][^;]+');
      expect(segment.firstMatch(ranged)!.group(0), segment.firstMatch(full)!.group(0));
    });

    // Every clip carries its own source `trim`, so the question is whether
    // the *output* chain — the one producing vout — carries one.
    String outputChain(String graph) => graph
        .split(';')
        .firstWhere((c) => c.contains('[vout'));

    test('no range leaves the output chain untrimmed', () {
      expect(outputChain(_compile().filterGraph), isNot(contains('trim=')));
    });

    test('a full-length range is treated as no range', () {
      final graph = _compile(
        range: const ExportRange(
          start: Duration.zero,
          end: Duration(seconds: 60),
        ),
      ).filterGraph;
      expect(outputChain(graph), isNot(contains('trim=')));
    });

    test('a real range does trim the output chain', () {
      final graph = _compile(
        range: const ExportRange(
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
      ).filterGraph;
      expect(outputChain(graph), contains('trim=start=10:end=20'));
    });

    test('the graph stays wirable', () {
      final plan = _compile(
        range: const ExportRange(
          start: Duration(seconds: 5),
          end: Duration(seconds: 8),
        ),
      );
      expect(
        plan.warnings.where((w) => w.contains('Internal graph error')),
        isEmpty,
        reason: plan.warnings.join('; '),
      );
      expect(plan.videoOutLabel, isNotNull);
      expect(plan.audioOutLabel, isNotNull);
    });
  });
}
