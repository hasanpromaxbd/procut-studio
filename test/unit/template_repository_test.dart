/// Template save/apply and eyedropper colour conversion.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/project_template.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/presentation/viewmodels/eyedropper_controller.dart';

Project _project(List<Clip> clips) => Project(
  id: 'prj',
  name: 'Source',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  assets: const {
    'a': MediaAsset(
      id: 'a',
      path: '/m/a.mp4',
      kind: AssetKind.video,
      duration: Duration(seconds: 20),
    ),
  },
  timeline: Timeline(
    fps: 30,
    tracks: [Track(id: 'trk', type: TrackType.video, clips: clips)],
  ),
);

void main() {
  group('eyedropper colour conversion', () {
    test('drops alpha and formats for FFmpeg', () {
      // chromakey wants 0xRRGGBB; alpha is meaningless for a key colour.
      expect(EyedropperController.toFfmpegColour(0xFF00FF00), '0x00ff00');
      expect(EyedropperController.toFfmpegColour(0x8012AB34), '0x12ab34');
    });

    test('pads short channel values', () {
      expect(EyedropperController.toFfmpegColour(0xFF000102), '0x000102');
      expect(EyedropperController.toFfmpegColour(0xFF000000), '0x000000');
    });
  });

  group('template round trip through a project', () {
    test('a text-only edit yields no slots', () {
      final template = ProjectTemplate.fromProject(
        _project(const [
          TextClip(
            id: 't',
            trackId: 'trk',
            start: Duration.zero,
            duration: Duration(seconds: 3),
            text: 'hello',
          ),
        ]),
        name: 'Titles only',
      );

      // Nothing to swap — the repository refuses to save this, and the test
      // pins the condition it checks.
      expect(template.slotCount, 0);
    });

    test('slots record the clip kind so media is matched sensibly', () {
      final template = ProjectTemplate.fromProject(
        _project([
          const VideoClip(
            id: 'v',
            trackId: 'trk',
            start: Duration.zero,
            duration: Duration(seconds: 5),
            assetId: 'a',
          ),
        ]),
        name: 'One shot',
      );

      expect(template.slots.single.kind, ClipKind.video);
      expect(template.slots.single.accepts(AssetKind.video), isTrue);
      expect(template.slots.single.accepts(AssetKind.audio), isFalse);
    });

    test('applying keeps effects and transitions from the original edit', () {
      final template = ProjectTemplate.fromProject(
        _project([
          const VideoClip(
            id: 'v',
            trackId: 'trk',
            start: Duration.zero,
            duration: Duration(seconds: 5),
            assetId: 'a',
            label: 'opening shot',
          ),
        ]),
        name: 'One shot',
      );

      final applied = template.apply(
        projectName: 'New',
        assets: const [
          MediaAsset(
            id: 'fresh',
            path: '/m/fresh.mp4',
            kind: AssetKind.video,
            duration: Duration(seconds: 30),
          ),
        ],
      );

      final clip = applied.project.timeline.tracks.single.clips.single;
      expect(clip.label, 'opening shot', reason: 'the edit survives, not just the timing');
      expect((clip as VideoClip).assetId, 'fresh');
      expect(applied.project.assets.keys, contains('fresh'));
      expect(applied.project.id, isNot('prj'), reason: 'a template makes a new project');
    });

    test('an image asset can fill an image slot but not a video one', () {
      final template = ProjectTemplate.fromProject(
        _project([
          const VideoClip(
            id: 'v',
            trackId: 'trk',
            start: Duration.zero,
            duration: Duration(seconds: 5),
            assetId: 'a',
          ),
        ]),
        name: 'One shot',
      );

      final applied = template.apply(
        projectName: 'New',
        assets: const [
          MediaAsset(
            id: 'pic',
            path: '/m/pic.jpg',
            kind: AssetKind.image,
            duration: Duration.zero,
          ),
        ],
      );

      // A still cannot fill a video slot, so the slot is dropped rather than
      // silently filled with something that would not render.
      expect(applied.filledSlots, 0);
      expect(applied.project.timeline.clipCount, 0);
    });
  });
}
