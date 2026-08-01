/// Face retouch and colour grading, as they reach the export.
///
/// Both are "colour" effects, but they fail in different ways. Retouch is a
/// branching graph, so its failure mode is a graph that does not wire up.
/// Grading is a chain of six filters whose *order* is the feature, and whose
/// numbers have to match the preview shader — so its failure mode is a picture
/// that looks one way while scrubbing and another way on export.
///
/// The numbers in `colorbalanceResponse` are measured from a real FFmpeg run.
/// `tool/verify_grade.sh` re-measures them; this test only pins them so a
/// change to the model cannot slip through without someone re-running it.
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
import 'package:procut_studio/engine/effects/grade_compiler.dart';
import 'package:procut_studio/engine/effects/grade_looks.dart';
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

Effect _effect(
  EffectType type,
  Map<String, double> values, {
  String id = 'fx1',
  Map<String, AnimatableDouble> animated = const {},
}) => Effect(
  id: id,
  type: type,
  params: {
    for (final e in values.entries) e.key: AnimatableDouble.constant(e.value),
    ...animated,
  },
);

RenderPlan _compile(List<Effect> effects) => const TimelineCompiler().compile(
  project: Project(
    id: 'p',
    name: 'G',
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
        Track(
          id: 'v1',
          type: TrackType.video,
          clips: [
            VideoClip(
              id: 'c',
              trackId: 'v1',
              start: Duration.zero,
              duration: const Duration(seconds: 4),
              assetId: 'a',
              effects: effects,
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
);

ResolvedEffect _grade(Map<String, double> values) =>
    ResolvedEffect(type: EffectType.colorGrade, intensity: 1, values: values);

void main() {
  group('face retouch', () {
    test('smooths through a mask rather than the whole frame', () {
      final graph = _compile([
        _effect(EffectType.faceRetouch, {'smooth': 0.6, 'glow': 0.3}),
      ]).filterGraph;

      expect(graph, contains('bilateral'));
      expect(graph, contains('maskedmerge'));
      // A blur with no mask would smooth eyes and hair too, which is the whole
      // difference between retouching and softening.
      expect(graph, contains('geq'));
    });

    test('the graph wires up', () {
      final plan = _compile([
        _effect(EffectType.faceRetouch, {'smooth': 0.6}),
      ]);
      expect(
        plan.warnings.where((w) => w.contains('Internal graph error')),
        isEmpty,
        reason: plan.warnings.join('; '),
      );
    });

    test('a curve value is quoted exactly once', () {
      // `escapeValue` quotes anything containing spaces. Quoting at the call
      // site as well produces all='\'…\'', which FFmpeg refuses to parse — and
      // it takes the entire graph with it, not just the one filter.
      final graph = _compile([
        _effect(EffectType.faceRetouch, {'smooth': 0.4, 'glow': 0.5}),
      ]).filterGraph;
      expect(graph, contains("curves=all='0/0"));
      expect(graph, isNot(contains(r"all='\'")));
    });

    test('every control at zero emits nothing', () {
      final graph = _compile([
        _effect(EffectType.faceRetouch, {
          'smooth': 0,
          'glow': 0,
          'clarity': 0,
        }),
      ]).filterGraph;
      expect(graph, isNot(contains('bilateral')));
      expect(graph, isNot(contains('maskedmerge')));
    });
  });

  group('grade — filter order', () {
    late String graph;

    setUp(() {
      graph = _compile([
        _effect(EffectType.colorGrade, {
          'warmth': 0.4,
          'tint': 0.2,
          'contrast': 0.3,
          'pivot': 0.5,
          'shadows': 0.2,
          'highlights': -0.1,
          'liftX': -0.4,
          'liftY': -0.3,
          'gainX': 0.3,
          'gainY': 0.3,
          'vibrance': 0.3,
          'saturation': 1.2,
        }),
      ]).filterGraph;
    });

    test('every stage reaches the graph', () {
      for (final filter in [
        'colortemperature',
        'colorchannelmixer',
        'curves',
        'colorbalance',
        'vibrance',
        'hue',
      ]) {
        expect(graph, contains(filter), reason: '$filter is missing');
      }
    });

    test('white balance comes before saturation', () {
      // Saturating first amplifies the cast the balance is about to remove,
      // and the result is a grade that fights itself.
      expect(
        graph.indexOf('colortemperature'),
        lessThan(graph.indexOf('vibrance')),
      );
      expect(graph.indexOf('curves'), lessThan(graph.indexOf('colorbalance')));
    });

    test('each filter appears once', () {
      // Two instances of one filter inside a single effect would leave the
      // second unaddressable by sendcmd — it would silently freeze.
      for (final filter in ['colorbalance', 'curves', 'colortemperature']) {
        expect(
          RegExp('(^|[,;\\[])$filter[=@,]').allMatches(graph).length,
          1,
          reason: '$filter appears more than once',
        );
      }
    });

    test('a neutral grade emits nothing at all', () {
      final neutral = _compile([
        _effect(EffectType.colorGrade, GradeLooks.neutral.values),
      ]).filterGraph;
      for (final filter in [
        'colortemperature',
        'curves',
        'colorbalance',
        'vibrance',
      ]) {
        expect(neutral, isNot(contains(filter)));
      }
    });
  });

  group('grade — the numbers', () {
    test('warmth right means a lower colour temperature', () {
      // The control says "warmth" precisely so this inversion never has to be
      // explained: a warm picture is what a low-Kelvin lamp gives you.
      expect(GradeCompiler.kelvinFor(1), lessThan(6500));
      expect(GradeCompiler.kelvinFor(-1), greaterThan(6500));
      expect(GradeCompiler.kelvinFor(0), closeTo(6500, 1));
    });

    test('a wheel push raises one channel and lowers the other two', () {
      // Straight up is red on the wheel.
      final red = GradeWheel.fromPosition(0, 1);
      expect(red.r, greaterThan(0));
      expect(red.g, lessThan(0));
      expect(red.b, lessThan(0));
      // Sum near zero is what makes it a hue push rather than a brightness one.
      expect(red.r + red.g + red.b, closeTo(0, 1e-6));
    });

    test('the centre of a wheel is neutral', () {
      expect(GradeWheel.fromPosition(0, 0).isNeutral, isTrue);
      expect(GradeWheel.fromPosition(0.001, 0).isNeutral, isTrue);
    });

    test('a wheel saturates at the rim instead of running away', () {
      final rim = GradeWheel.fromPosition(0, 1);
      final past = GradeWheel.fromPosition(0, 4);
      expect(past.r, closeTo(rim.r, 1e-9));
    });

    test('zone weights always sum to one', () {
      for (var i = 0; i <= 20; i++) {
        final (s, m, h) = GradeCompiler.zoneWeights(i / 20);
        expect(s + m + h, closeTo(1, 1e-9), reason: 'at l=${i / 20}');
      }
    });

    test('zone weights match colorbalance’s measured response', () {
      // Measured with `colorbalance=rs=0.2` on a full ramp; see
      // tool/verify_grade.sh. Lightness → shadow weight.
      const measured = [
        (0.0, 1.0),
        (0.0627, 1.0),
        (0.1255, 0.833),
        (0.1882, 0.333),
        (0.251, 0.0),
        (0.5, 0.0),
      ];
      for (final (l, expected) in measured) {
        final (shadows, _, _) = GradeCompiler.zoneWeights(l);
        expect(
          shadows,
          closeTo(expected, 0.15),
          reason: 'shadow weight at l=$l',
        );
      }
    });

    test('contrast pivots where it is told to', () {
      double at(double x, double pivot) => GradeCompiler.toneValue(
        x,
        contrast: 0.8,
        pivot: pivot,
        shadows: 0,
        highlights: 0,
      );
      // The pivot is the level the curve leaves alone.
      expect(at(0.5, 0.5), closeTo(0.5, 0.01));
      expect(at(0.3, 0.3), closeTo(0.3, 0.02));
      // Below the pivot it darkens, above it brightens.
      expect(at(0.25, 0.5), lessThan(0.25));
      expect(at(0.75, 0.5), greaterThan(0.75));
    });

    test('contrast never pushes an endpoint past the end', () {
      for (final pivot in [0.25, 0.5, 0.75]) {
        for (final contrast in [-1.0, 1.0]) {
          for (var i = 0; i <= 20; i++) {
            final y = GradeCompiler.toneValue(
              i / 20,
              contrast: contrast,
              pivot: pivot,
              shadows: 0,
              highlights: 0,
            );
            expect(y, inInclusiveRange(0, 1));
          }
        }
      }
    });

    test('shadows and highlights reach their own end of the range', () {
      double shadowLift(double x) => GradeCompiler.toneValue(
        x,
        contrast: 0,
        pivot: 0.5,
        shadows: 1,
        highlights: 0,
      );
      expect(shadowLift(0.05), greaterThan(0.05));
      expect(shadowLift(0.9), closeTo(0.9, 1e-9));

      double highlightLift(double x) => GradeCompiler.toneValue(
        x,
        contrast: 0,
        pivot: 0.5,
        shadows: 0,
        highlights: 1,
      );
      expect(highlightLift(0.9), greaterThan(0.9));
      expect(highlightLift(0.05), closeTo(0.05, 1e-9));
    });

    test('an identity tone curve is not emitted', () {
      expect(
        GradeCompiler.tonePoints(
          contrast: 0,
          pivot: 0.5,
          shadows: 0,
          highlights: 0,
        ),
        isNull,
      );
    });

    test('tone points are ordered and in range', () {
      final points = GradeCompiler.tonePoints(
        contrast: 1,
        pivot: 0.4,
        shadows: 1,
        highlights: -1,
      )!;
      var previousX = -1.0;
      for (final point in points.split(' ')) {
        final parts = point.split('/');
        final x = double.parse(parts[0]);
        final y = double.parse(parts[1]);
        expect(x, greaterThan(previousX));
        expect(y, inInclusiveRange(0, 1));
        previousX = x;
      }
    });
  });

  group('grade — looks', () {
    test('every look sets every control', () {
      final keys = EffectCatalog.specFor(EffectType.colorGrade)!.params
          .map((p) => p.key)
          .toSet();
      for (final look in GradeLooks.all) {
        expect(
          look.values.keys.toSet(),
          keys,
          reason: '${look.label} does not account for every control',
        );
      }
    });

    test('every value is inside its control’s range', () {
      final spec = EffectCatalog.specFor(EffectType.colorGrade)!;
      for (final look in GradeLooks.all) {
        look.values.forEach((key, value) {
          final param = spec.param(key)!;
          expect(
            value,
            inInclusiveRange(param.min, param.max),
            reason: '${look.label}.$key',
          );
        });
      }
    });

    test('the neutral look really is neutral', () {
      expect(GradeCompiler.build(_grade(GradeLooks.neutral.values)), isEmpty);
    });

    test('every other look does something', () {
      for (final look in GradeLooks.all.where((l) => l.id != 'neutral')) {
        expect(
          GradeCompiler.build(_grade(look.values)),
          isNotEmpty,
          reason: '${look.label} renders as a no-op',
        );
      }
    });
  });

  group('grade — animation', () {
    Effect animatedGrade() => _effect(
      EffectType.colorGrade,
      {'saturation': 1, 'pivot': 0.5},
      id: 'g1',
      animated: {
        'contrast': const AnimatableDouble(
          0,
          keyframes: [
            Keyframe(time: Duration.zero, value: 0),
            Keyframe(time: Duration(seconds: 4), value: 0.8),
          ],
        ),
        'gainX': const AnimatableDouble(
          0,
          keyframes: [
            Keyframe(time: Duration.zero, value: 0),
            Keyframe(time: Duration(seconds: 4), value: 0.6),
          ],
        ),
      },
    );

    test('the wheels animate on export', () {
      final plan = _compile([animatedGrade()]);
      final script = plan.commandScripts.single.contents;
      expect(script, contains('colorbalance@fxg1 rh'));
    });

    test('so does the tone curve', () {
      // A grade whose wheels move while its curve sits frozen is worse than
      // one that does not animate at all: the user sees movement and assumes
      // the rest was meant to stay put.
      final script = _compile([animatedGrade()]).commandScripts.single.contents;
      expect(script, contains('curves@fxg1 all'));
      // The points list has spaces in it, so sendcmd needs it as one token.
      expect(RegExp(r"curves@fxg1 all '[^']+';").hasMatch(script), isTrue);
    });

    test('a grade and an adjust do not steal each other’s filters', () {
      // Both emit `colorbalance`. Labelling across the merged list would give
      // the grade's commands to the adjust's instance.
      final plan = _compile([
        _effect(EffectType.colorAdjust, {'temperature': 0.5}, id: 'a1'),
        animatedGrade(),
      ]);
      final graph = plan.filterGraph;
      // The labelled instance must be the grade's — the one with nine
      // channels, not the adjust's two.
      expect(graph, contains('colorbalance@fxg1=rs='));
      expect(
        plan.warnings.where((w) => w.contains('Internal graph error')),
        isEmpty,
        reason: plan.warnings.join('; '),
      );
    });
  });
}
