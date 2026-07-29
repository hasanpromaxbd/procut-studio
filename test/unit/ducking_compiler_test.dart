/// Ducking, as it reaches the FFmpeg graph.
///
/// The behaviour that matters is not "sidechaincompress appears" — it is that
/// the key track survives into the mix. `tool/verify_ducking.sh` proves the
/// same graph shape runs and actually ducks; these tests pin the shape so a
/// refactor cannot quietly drop the split.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/ducking.dart';
import 'package:procut_studio/domain/entities/export_settings.dart';
import 'package:procut_studio/domain/entities/media_asset.dart';
import 'package:procut_studio/domain/entities/project.dart';
import 'package:procut_studio/domain/entities/timeline.dart';
import 'package:procut_studio/domain/entities/track.dart';
import 'package:procut_studio/engine/export/render_plan.dart';
import 'package:procut_studio/engine/export/timeline_compiler.dart';
import 'package:procut_studio/engine/ffmpeg/ffmpeg_service.dart';
import 'package:procut_studio/engine/ffmpeg/hardware_encoder.dart';

const _music = MediaAsset(
  id: 'music',
  path: '/media/music.mp3',
  kind: AssetKind.audio,
  duration: Duration(seconds: 60),
  hasAudioStream: true,
);

const _voice = MediaAsset(
  id: 'voice',
  path: '/media/voice.m4a',
  kind: AssetKind.audio,
  duration: Duration(seconds: 60),
  hasAudioStream: true,
);

const _video = MediaAsset(
  id: 'video',
  path: '/media/clip.mp4',
  kind: AssetKind.video,
  duration: Duration(seconds: 60),
  width: 1920,
  height: 1080,
  hasVideoStream: true,
  hasAudioStream: false,
);

AudioClip _audio(String id, String trackId, String assetId) => AudioClip(
  id: id,
  trackId: trackId,
  start: Duration.zero,
  duration: const Duration(seconds: 10),
  assetId: assetId,
);

Project _project({Ducking? ducking, List<AudioClip>? musicClips}) => Project(
  id: 'prj',
  name: 'Ducked',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  assets: const {'music': _music, 'voice': _voice, 'video': _video},
  timeline: Timeline(
    fps: 30,
    width: 1080,
    height: 1920,
    tracks: [
      Track(
        id: 'v1',
        type: TrackType.video,
        clips: [
          const VideoClip(
            id: 'vc',
            trackId: 'v1',
            start: Duration.zero,
            duration: Duration(seconds: 10),
            assetId: 'video',
          ),
        ],
      ),
      Track(
        id: 'music',
        type: TrackType.audio,
        name: 'Music',
        clips: musicClips ?? [_audio('m1', 'music', 'music')],
        ducking: ducking,
      ),
      Track(
        id: 'voice',
        type: TrackType.audio,
        name: 'Voice',
        clips: [_audio('v1c', 'voice', 'voice')],
      ),
    ],
  ),
);

RenderPlan _compile(Project project) => const TimelineCompiler().compile(
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

String _graph(RenderPlan plan) => plan.filterGraph;

final _label = RegExp(r'\[([^\]]+)\]');
final _filePad = RegExp(r'^\d+:[va]$');

/// Labels that go nowhere, or come from nowhere.
///
/// This is the check that catches a dropped `asplit` branch: FFmpeg refuses a
/// graph with an unconnected output, and the whole export dies at the first
/// frame rather than at compile time.
List<String> _problems(RenderPlan plan) {
  final produced = <String>{};
  final consumed = <String>{};

  for (final chain in plan.filterGraph.split(';')) {
    final labels = _label.allMatches(chain).toList();
    if (labels.isEmpty) continue;

    // Inputs are the bracket groups before the first filter name; outputs are
    // the ones after the last.
    final firstBody = chain.indexOf(RegExp(r'[^\[\]]'), 0);
    for (final match in labels) {
      final isLeading = chain.substring(0, match.start).trim().replaceAll(
            _label,
            '',
          ).isEmpty;
      if (isLeading && firstBody >= 0) {
        consumed.add(match.group(1)!);
      } else {
        produced.add(match.group(1)!);
      }
    }
  }

  final mapped = <String>{
    if (plan.videoOutLabel != null) plan.videoOutLabel!,
    if (plan.audioOutLabel != null) plan.audioOutLabel!,
  };

  return [
    for (final label in consumed)
      if (!_filePad.hasMatch(label) && !produced.contains(label))
        'unproduced: $label',
    for (final label in produced)
      if (!consumed.contains(label) && !mapped.contains(label))
        'unconsumed: $label',
  ];
}

void main() {
  group('without ducking', () {
    test('no side-chain appears', () {
      expect(_graph(_compile(_project())), isNot(contains('sidechaincompress')));
    });
  });

  group('with ducking', () {
    final plan = _compile(
      _project(
        ducking: const Ducking(
          keyTrackId: 'voice',
          strength: 8,
          sensitivity: 0.04,
          release: Duration(milliseconds: 400),
        ),
      ),
    );
    final graph = _graph(plan);

    test('the compressor carries the settings the user chose', () {
      expect(graph, contains('sidechaincompress='));
      expect(graph, contains('ratio=8'));
      expect(graph, contains('threshold=0.04'));
      expect(graph, contains('release=400'));
    });

    test('the key track is split so it stays audible', () {
      // Without the split, the voice is consumed by the compressor and is
      // simply missing from the export — the failure this whole test exists
      // for.
      expect(graph, contains('asplit=2'));
      expect(_problems(plan), isEmpty, reason: 'every label must be consumed');
    });

    test('makeup gain is off', () {
      // Compression that makes up gain pushes the music back up between
      // words, which is the opposite of what ducking is for.
      expect(graph, contains('makeup=1'));
    });

    test('the export still produces a mix, not just the ducked branch', () {
      expect(graph, contains('amix='));
    });
  });

  test('a track with several music clips ducks as one, not clip by clip', () {
    final plan = _compile(
      _project(
        ducking: const Ducking(keyTrackId: 'voice'),
        musicClips: [
          _audio('m1', 'music', 'music'),
          AudioClip(
            id: 'm2',
            trackId: 'music',
            start: const Duration(seconds: 10),
            duration: const Duration(seconds: 10),
            assetId: 'music',
          ),
        ],
      ),
    );
    final graph = _graph(plan);

    // One compressor, not one per clip: the level should follow the voice,
    // not restart at every cut in the music.
    expect('sidechaincompress'.allMatches(graph).length, 1);
    expect(_problems(plan), isEmpty);
  });

  test('ducking under a silent track is a warning, not a broken graph', () {
    final plan = _compile(
      _project(ducking: const Ducking(keyTrackId: 'v1')),
    );
    // 'v1' is the video track and its asset has no audio stream, so there is
    // no key signal to duck under.
    expect(_graph(plan), isNot(contains('sidechaincompress')));
    expect(plan.warnings.join(' '), contains('ducking was skipped'));
    expect(_problems(plan), isEmpty);
  });

  test('a track told to duck under itself is refused with a warning', () {
    final plan = _compile(
      _project(ducking: const Ducking(keyTrackId: 'music')),
    );
    expect(_graph(plan), isNot(contains('sidechaincompress')));
    expect(plan.warnings.join(' '), contains('duck under itself'));
    expect(_problems(plan), isEmpty);
  });

  group('the reduction estimate', () {
    test('is zero while the key is below the threshold', () {
      const duck = Ducking(keyTrackId: 'voice', sensitivity: 0.1, strength: 8);
      // 0.1 linear is −20 dB; a −30 dB signal is under it.
      expect(duck.reductionDbFor(-30), 0);
    });

    test('grows with both ratio and how far over the key sits', () {
      const gentle = Ducking(keyTrackId: 'v', sensitivity: 0.1, strength: 2);
      const hard = Ducking(keyTrackId: 'v', sensitivity: 0.1, strength: 16);
      expect(hard.reductionDbFor(-6), greaterThan(gentle.reductionDbFor(-6)));
      expect(hard.reductionDbFor(-2), greaterThan(hard.reductionDbFor(-10)));
    });

    test('ratio 1 is no compression at all', () {
      const off = Ducking(keyTrackId: 'v', strength: 1);
      expect(off.isActive, isFalse);
      expect(off.reductionDbFor(0), 0);
    });
  });
}
