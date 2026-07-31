/// Where a layer actually lands in the export.
///
/// The preview translates and scales a layer by its transform. These tests
/// exist because the export did not: it padded every layer to the canvas
/// centred, then overlaid at 0,0 — so a moved PiP snapped back to the middle
/// and a scaled one came out unscaled. What you see must be what you get.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/keyframe.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/domain/entities/transform2d.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

/// 16:9 source on a 1080×1920 vertical canvas: fits to 1080×608.
const _wide = MediaAsset(
  id: 'wide',
  path: '/media/wide.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: true,
);

const _canvasW = 1080;
const _canvasH = 1920;

/// The fitted height of [_wide] on this canvas — the baseline a transform
/// scales *from*. Width fits the canvas exactly at 1080.
const _fitH = 608; // 1080 × 1080/1920, rounded to even

Project _project(List<Track> tracks) => Project(
  id: 'p',
  name: 'Placement',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  assets: const {'wide': _wide},
  timeline: Timeline(
    fps: 30,
    width: _canvasW,
    height: _canvasH,
    tracks: tracks,
  ),
);

VideoClip _clip(String id, String trackId, {Transform2D? transform}) =>
    VideoClip(
      id: id,
      trackId: trackId,
      start: Duration.zero,
      duration: const Duration(seconds: 5),
      assetId: 'wide',
      transform: transform ?? Transform2D.identity,
    );

RenderPlan _compile(Project project) => const TimelineCompiler().compile(
  project: project,
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

Transform2D _at({double x = 0, double y = 0, double scale = 1}) =>
    Transform2D.identity.copyWith(
      x: AnimatableDouble(x),
      y: AnimatableDouble(y),
      scaleX: AnimatableDouble(scale),
      scaleY: AnimatableDouble(scale),
    );

void main() {
  group('position', () {
    test('a centred layer pads evenly', () {
      final graph = _compile(
        _project([
          Track(id: 'v1', type: TrackType.video, clips: [_clip('a', 'v1')]),
        ]),
      ).filterGraph;

      // Centred: (1920 − 608) / 2 = 656.
      expect(graph, contains('pad=w=$_canvasW:h=$_canvasH:x=0:y=656'));
    });

    test('a moved layer pads off-centre by exactly the transform', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('a', 'v1', transform: _at(x: 0.25, y: -0.1))],
          ),
        ]),
      ).filterGraph;

      // x: 0 + 0.25×1080 = 270. y: 656 − 0.1×1920 = 464.
      expect(
        graph,
        contains('pad=w=$_canvasW:h=$_canvasH:x=270:y=464'),
        reason: 'the preview moves the layer; the export must agree',
      );
    });

    test('a layer pushed off the canvas is cropped, not clamped back', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('a', 'v1', transform: _at(x: -0.5))],
          ),
        ]),
      ).filterGraph;

      // Left edge at −540: half the layer is off-canvas, so the visible half
      // is cropped out of it and padded at x=0.
      expect(graph, contains('crop=w=540:h=$_fitH:x=540:y=0'));
      expect(graph, contains('pad=w=$_canvasW:h=$_canvasH:x=0:y=656'));
    });
  });

  group('scale', () {
    test('a scaled layer is actually scaled', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('a', 'v1', transform: _at(scale: 0.5))],
          ),
        ]),
      ).filterGraph;

      // Half of the fitted size, centred on the canvas.
      expect(graph, contains('scale=w=540:h=304'));
      expect(graph, contains('pad=w=$_canvasW:h=$_canvasH:x=270:y=808'));
    });

    test('scaling past the canvas crops rather than shrinking back', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('a', 'v1', transform: _at(scale: 2))],
          ),
        ]),
      ).filterGraph;

      // 2160×1216 on a 1080-wide canvas: the sides are cropped away.
      expect(graph, contains('scale=w=2160:h=1216'));
      expect(graph, contains('crop=w=1080:h=1216:x=540:y=0'));
    });

    test('a scaled *and* moved PiP combines both', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [
              _clip('a', 'v1', transform: _at(scale: 0.3, x: 0.3, y: -0.35)),
            ],
          ),
        ]),
      ).filterGraph;

      // 1080×0.3 = 324, 608×0.3 = 182 (rounded even).
      expect(graph, contains('scale=w=324:h=182'));
      // x: (1080−324)/2 + 0.3×1080 = 378 + 324 = 702
      // y: (1920−182)/2 − 0.35×1920 = 869 − 672 = 197
      expect(graph, contains('pad=w=$_canvasW:h=$_canvasH:x=702:y=197'));
    });
  });

  group('animation', () {
    Transform2D ramp() => Transform2D.identity.copyWith(
      scaleX: const AnimatableDouble(
        1,
        keyframes: [
          Keyframe(time: Duration.zero, value: 1),
          Keyframe(time: Duration(seconds: 5), value: 1.4),
        ],
      ),
      scaleY: const AnimatableDouble(
        1,
        keyframes: [
          Keyframe(time: Duration.zero, value: 1),
          Keyframe(time: Duration(seconds: 5), value: 1.4),
        ],
      ),
    );

    test('an animated transform on VIDEO renders, it does not freeze', () {
      final graph = _compile(
        _project([
          Track(
            id: 'v1',
            type: TrackType.video,
            clips: [_clip('a', 'v1', transform: ramp())],
          ),
        ]),
      ).filterGraph;

      // The static placement path reads `.staticValue` and would emit one
      // fixed scale; a real move goes through zoompan.
      expect(graph, contains('zoompan'));
      expect(graph, contains('1+(0.4)'), reason: 'the ramp must reach 1.4');
    });

    test('an animated overlay layer keeps its surround transparent', () {
      final graph = _compile(
        _project([
          Track(id: 'v1', type: TrackType.video, clips: [_clip('a', 'v1')]),
          Track(
            id: 'v2',
            type: TrackType.overlay,
            clips: [_clip('b', 'v2', transform: ramp())],
          ),
        ]),
      ).filterGraph;

      // The oversampled fit the camera move pads to must not be opaque, or
      // an animated PiP blacks out the picture underneath.
      expect(
        RegExp(r'pad=w=2160:h=3840[^,;]*color=0x000000(?!@)').hasMatch(graph),
        isFalse,
      );
    });
  });

  group('stacking', () {
    test('an upper track does not black out the one beneath it', () {
      final plan = _compile(
        _project([
          Track(id: 'v1', type: TrackType.video, clips: [_clip('a', 'v1')]),
          Track(
            id: 'v2',
            type: TrackType.overlay,
            clips: [_clip('b', 'v2', transform: _at(scale: 0.4, y: -0.3))],
          ),
        ]),
      );

      // The padding around an overlay layer must be transparent; opaque black
      // would hide the whole picture below it.
      // FFmpeg spells transparent black `0x000000@0`; an opaque `0x000000`
      // surround is exactly the bug.
      expect(plan.filterGraph, contains('color=0x000000@0'));
      expect(
        RegExp(r'pad=[^,;]*color=0x000000(?!@)').hasMatch(plan.filterGraph),
        isFalse,
        reason: 'no layer may pad itself with opaque black',
      );
    });

    test('the bottom track still fills the frame opaquely', () {
      // The base colour source underneath everything is what makes the frame
      // opaque; layers themselves never need to be.
      final graph = _compile(
        _project([
          Track(id: 'v1', type: TrackType.video, clips: [_clip('a', 'v1')]),
        ]),
      ).filterGraph;
      expect(graph, startsWith('color=c='));
    });
  });
}
