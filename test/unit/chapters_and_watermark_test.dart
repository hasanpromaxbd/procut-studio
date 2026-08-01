/// Chapter timestamp lists and the export watermark.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/marker.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/watermark.dart';
import 'package:procut_studio/domain/usecases/chapter_export.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

Marker _chapter(int seconds, String label) => Marker(
  id: 'm$seconds',
  time: Duration(seconds: seconds),
  label: label,
  kind: MarkerKind.chapter,
);

const _asset = MediaAsset(
  id: 'a',
  path: '/media/a.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
);

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

RenderPlan _compile(Watermark mark) => const TimelineCompiler().compile(
  project: Project(
    id: 'p',
    name: 'W',
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
              duration: Duration(seconds: 10),
              assetId: 'a',
            ),
          ],
        ),
      ],
    ),
  ),
  settings: ExportSettings(watermark: mark),
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
  group('chapters', () {
    test('formats a YouTube list', () {
      final text = ChapterExport.format(
        [_chapter(0, 'Intro'), _chapter(75, 'The middle'), _chapter(200, 'End')],
        const Duration(seconds: 300),
      );
      expect(text, '0:00 Intro\n1:15 The middle\n3:20 End');
    });

    test('prepends a zero chapter when the list starts late', () {
      // YouTube ignores the whole list if it does not begin at 0:00, so a
      // silent no-op is the worst outcome here.
      final text = ChapterExport.format(
        [_chapter(30, 'Later'), _chapter(60, 'Even later')],
        const Duration(seconds: 120),
      );
      expect(text.split('\n').first, '0:00 Start');
    });

    test('past an hour the stamp grows an hours field', () {
      final text = ChapterExport.format(
        [_chapter(0, 'A'), _chapter(3725, 'B')],
        const Duration(hours: 2),
      );
      expect(text, contains('1:02:05 B'));
    });

    test('unnamed chapters are numbered rather than left blank', () {
      final text = ChapterExport.format(
        [_chapter(0, ''), _chapter(10, '')],
        const Duration(seconds: 60),
      );
      expect(text, contains('Chapter 1'));
      expect(text, contains('Chapter 2'));
    });

    test('two chapters in the same second collapse', () {
      final prepared = ChapterExport.prepare([
        _chapter(0, 'A'),
        Marker(
          id: 'x',
          time: const Duration(milliseconds: 400),
          label: 'B',
          kind: MarkerKind.chapter,
        ),
      ]);
      expect(prepared, hasLength(1));
    });

    test('note markers are not chapters', () {
      final text = ChapterExport.format(
        [
          _chapter(0, 'Real'),
          const Marker(id: 'n', time: Duration(seconds: 5), label: 'A note'),
        ],
        const Duration(seconds: 60),
      );
      expect(text, isNot(contains('A note')));
    });

    test('says why a short list will not work on YouTube', () {
      expect(
        ChapterExport.youtubeProblem([_chapter(0, 'A'), _chapter(5, 'B')]),
        contains('at least three'),
      );
      expect(
        ChapterExport.youtubeProblem([
          _chapter(0, 'A'),
          _chapter(5, 'B'),
          _chapter(9, 'C'),
        ]),
        isNull,
      );
    });

    test('WebVTT gives every chapter an end time', () {
      final vtt = ChapterExport.format(
        [_chapter(0, 'One'), _chapter(10, 'Two')],
        const Duration(seconds: 30),
        format: ChapterFormat.webvtt,
      );
      expect(vtt, startsWith('WEBVTT'));
      expect(vtt, contains('00:00:00.000 --> 00:00:10.000'));
      // The last chapter runs to the end of the programme.
      expect(vtt, contains('00:00:10.000 --> 00:00:30.000'));
    });
  });

  group('watermark', () {
    test('an inactive one changes nothing', () {
      expect(_compile(Watermark.none).filterGraph, isNot(contains('overlay=x=W-w')));
    });

    test('is composited into the corner it was given', () {
      final graph = _compile(
        const Watermark(imagePath: '/img/logo.png', margin: 0.05),
      ).filterGraph;
      // 0.05 × 1080 = 54.
      expect(graph, contains('overlay=x=W-w-54:y=H-h-54'));
    });

    test('every corner maps to the right expression', () {
      const mark = Watermark(imagePath: '/l.png', margin: 0.1);
      expect(mark.copyWith(corner: WatermarkCorner.topLeft)
          .overlayPosition(1000), ('100', '100'));
      expect(mark.copyWith(corner: WatermarkCorner.topRight)
          .overlayPosition(1000), ('W-w-100', '100'));
      expect(mark.copyWith(corner: WatermarkCorner.bottomLeft)
          .overlayPosition(1000), ('100', 'H-h-100'));
      expect(mark.copyWith(corner: WatermarkCorner.bottomRight)
          .overlayPosition(1000), ('W-w-100', 'H-h-100'));
    });

    test('the looped image is bounded, or the render never ends', () {
      final plan = _compile(const Watermark(imagePath: '/img/logo.png'));
      final input = plan.inputs.firstWhere((i) => i.path == '/img/logo.png');

      // `-loop 1` alone is an infinite stream; without `-t` the overlay waits
      // for it forever. This is not theoretical — it hung.
      expect(input.leadingArgs, contains('-loop'));
      expect(input.leadingArgs, contains('-t'));
      expect(plan.filterGraph, contains('shortest=1'));
    });

    test('keeps the logo aspect ratio', () {
      final graph = _compile(
        const Watermark(imagePath: '/l.png', scale: 0.2),
      ).filterGraph;
      // 0.2 × 1080 = 216 wide, height derived.
      expect(graph, contains('scale=w=216:h=-1'));
    });

    test('opacity reaches the alpha channel', () {
      final graph = _compile(
        const Watermark(imagePath: '/l.png', opacity: 0.4),
      ).filterGraph;
      expect(graph, contains('colorchannelmixer=aa=0.4'));
    });

    test('survives the settings round trip', () {
      const mark = Watermark(
        imagePath: '/l.png',
        corner: WatermarkCorner.topLeft,
        scale: 0.22,
        opacity: 0.5,
      );
      final restored = ExportSettings.fromJson(
        const ExportSettings(watermark: mark).toJson(),
      );
      expect(restored.watermark, mark);
    });
  });
}
