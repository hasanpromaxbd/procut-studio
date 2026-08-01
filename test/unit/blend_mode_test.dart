/// Blend modes, which lived only in the data model until now.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
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
);

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

VideoClip _clip(String id, String trackId, {LayerBlendMode? blend}) =>
    VideoClip(
      id: id,
      trackId: trackId,
      start: Duration.zero,
      duration: const Duration(seconds: 5),
      assetId: 'a',
      transform: blend == null
          ? Transform2D.identity
          : Transform2D.identity.copyWith(blendMode: blend),
    );

RenderPlan _compile({LayerBlendMode? upper}) =>
    const TimelineCompiler().compile(
      project: Project(
        id: 'p',
        name: 'B',
        createdAt: _epoch,
        updatedAt: _epoch,
        assets: const {'a': _asset},
        timeline: const Timeline(fps: 30, tracks: []),
      ).copyWith(
        timeline: Timeline(
          fps: 30,
          width: 1080,
          height: 1920,
          tracks: [
            Track(id: 'v1', type: TrackType.video, clips: [_clip('a', 'v1')]),
            Track(
              id: 'v2',
              type: TrackType.overlay,
              clips: [_clip('b', 'v2', blend: upper)],
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
    );

void main() {
  test('a normal layer still uses the cheap overlay', () {
    final graph = _compile().filterGraph;
    expect(graph, contains('overlay='));
    expect(graph, isNot(contains('blend=')));
  });

  test('a blended layer reaches the export', () {
    final graph = _compile(upper: LayerBlendMode.screen).filterGraph;
    expect(graph, contains('blend=all_mode=screen'));
  });

  test('every mode maps to a name ffmpeg knows', () {
    // Each of these was run through a real ffmpeg before being exposed.
    for (final mode in LayerBlendMode.values) {
      if (mode == LayerBlendMode.normal) continue;
      expect(
        _compile(upper: mode).filterGraph,
        contains('blend=all_mode=${mode.id}'),
      );
    }
  });

  test('the layer alpha is reattached before compositing', () {
    // `blend` ignores alpha, so used alone it mixes the transparent surround
    // with the base too — `multiply` would black out the whole frame.
    final graph = _compile(upper: LayerBlendMode.multiply).filterGraph;
    expect(graph, contains('alphaextract'));
    expect(graph, contains('alphamerge'));
    expect(
      graph.indexOf('blend='),
      lessThan(graph.indexOf('alphamerge')),
      reason: 'the mask is reattached to the blended result, not before it',
    );
  });

  test('the base is split rather than consumed twice', () {
    // A filter pad can only feed one consumer; blending needs the base for
    // both the blend and the final overlay.
    final graph = _compile(upper: LayerBlendMode.difference).filterGraph;
    expect(graph, contains('split=2'));
  });

  test('the graph stays wirable', () {
    final plan = _compile(upper: LayerBlendMode.overlay);
    expect(
      plan.warnings.where((w) => w.contains('Internal graph error')),
      isEmpty,
      reason: plan.warnings.join('; '),
    );
  });
}
