/// The single source of truth for what every effect *is*.
///
/// Each entry carries three things:
///   1. **UI metadata** — label, icon, parameter ranges for the inspector;
///   2. **an FFmpeg filter emitter** — used by the export engine;
///   3. **a GPU shader binding** — used by the 60fps preview.
///
/// Keeping all three together is deliberate. When preview and export are
/// defined in separate places they drift, and the user discovers it only after
/// waiting out a render. A test walks this catalogue and asserts every effect
/// defines both paths.
library;

import 'package:flutter/material.dart';

import '../../domain/entities/effect.dart';
import '../../domain/entities/keyframe.dart';
import '../ffmpeg/filter_graph.dart';
import 'grade_compiler.dart';
import 'retouch_compiler.dart';

/// One tunable knob on an effect.
@immutable
class EffectParamSpec {
  const EffectParamSpec({
    required this.key,
    required this.label,
    required this.min,
    required this.max,
    required this.defaultValue,
    this.unit = '',
    this.isAngle = false,
  });

  final String key;
  final String label;
  final double min;
  final double max;
  final double defaultValue;
  final String unit;
  final bool isAngle;

  double clamp(double value) => value.clamp(min, max);

  /// 0..1 position of [value] within the range, for slider widgets.
  double normalise(double value) =>
      max - min == 0 ? 0 : ((value - min) / (max - min)).clamp(0.0, 1.0);

  double denormalise(double t) => min + (max - min) * t.clamp(0.0, 1.0);
}

/// Binds an effect's animated value to a runtime-settable FFmpeg filter
/// parameter, so keyframed effects animate on export instead of freezing at
/// their `t=0` value.
///
/// Only filters that advertise command support (the `C` flag in
/// `ffmpeg -filters`) can be driven this way. The ones used here that
/// **cannot** are `unsharp`, `noise` and `vignette` — effects built on those
/// render with their first-frame value and say so in the inspector.
@immutable
class EffectCommandBinding {
  const EffectCommandBinding({
    required this.filter,
    required this.parameter,
    required this.valueAt,
  });

  /// FFmpeg filter name, e.g. `gblur`. Must match a filter emitted by
  /// [EffectSpec.buildFilters] — the compiler labels that instance so
  /// `sendcmd` can address it.
  final String filter;

  /// Parameter on that filter, e.g. `sigma`.
  final String parameter;

  /// Computes the value at an already-resolved instant. Deliberately the same
  /// arithmetic the static path uses, so an animated effect at a constant
  /// value renders identically to a non-animated one.
  final double Function(ResolvedEffect effect) valueAt;
}

/// The same binding for a parameter whose value is text rather than a number.
///
/// There is exactly one of these in practice — a tone curve, whose value is a
/// list of points — but a scalar binding cannot express it, and without it a
/// grade would animate its wheels while its curve sat frozen. A partly
/// animated effect is worse than an un-animated one: the user sees *some*
/// movement and assumes the rest is intentional.
@immutable
class EffectStringCommandBinding {
  const EffectStringCommandBinding({
    required this.filter,
    required this.parameter,
    required this.valueAt,
  });

  final String filter;
  final String parameter;

  /// Null means "nothing to say at this instant" — the previous value stands.
  /// A curve that is the identity emits no filter at all, so there would be
  /// nothing to address.
  final String? Function(ResolvedEffect effect) valueAt;
}

@immutable
class EffectSpec {
  const EffectSpec({
    required this.type,
    required this.label,
    required this.description,
    required this.icon,
    required this.stage,
    required this.params,
    required this.shaderAsset,
    required this.buildFilters,
    this.buildGraph,
    this.commands = const [],
    this.stringCommands = const [],
    this.isAudioEffect = false,
    this.requiresPreRender = false,
  });

  /// True when the effect cannot be expressed inline and the compiler must
  /// lift it into its own pass — currently only two-pass stabilisation.
  final bool requiresPreRender;

  /// Runtime-command bindings. Empty means this effect cannot be animated on
  /// export and renders at its `t=0` value.
  final List<EffectCommandBinding> commands;

  /// Text-valued command bindings — see [EffectStringCommandBinding].
  final List<EffectStringCommandBinding> stringCommands;

  bool get supportsExportAnimation =>
      commands.isNotEmpty || stringCommands.isNotEmpty;

  /// Every filter name this effect can drive at runtime.
  Set<String> get commandTargets => {
    for (final c in commands) c.filter,
    for (final c in stringCommands) c.filter,
  };

  final EffectType type;
  final String label;
  final String description;
  final IconData icon;
  final EffectStage stage;
  final List<EffectParamSpec> params;

  /// Fragment shader driving the live preview. `null` means the effect has no
  /// preview representation and the compositor shows it unapplied (currently
  /// only true for the audio-domain effects).
  final String? shaderAsset;

  /// Emits the FFmpeg filters for this effect at a resolved instant.
  final List<Filter> Function(ResolvedEffect effect) buildFilters;

  /// For effects that need a *branching* graph rather than a linear chain —
  /// anything that has to combine the frame with a processed copy of itself.
  ///
  /// Takes the label carrying the frame so far and returns the label carrying
  /// the result. When set, [buildFilters] is not used.
  final String Function(FilterGraph graph, String input, ResolvedEffect effect)?
  buildGraph;

  bool get needsGraph => buildGraph != null;

  final bool isAudioEffect;

  /// A ready-to-use instance with catalogue defaults.
  Effect instantiate(String id) => Effect(
    id: id,
    type: type,
    params: {
      for (final p in params) p.key: AnimatableDouble.constant(p.defaultValue),
    },
  );

  EffectParamSpec? param(String key) {
    for (final p in params) {
      if (p.key == key) return p;
    }
    return null;
  }
}

/// One of the grade's three wheels, resolved the same way the compiler does.
///
/// The command bindings and [GradeCompiler.build] must agree exactly: the
/// filter instance is built from the second and then driven by the first, so
/// any difference shows up as a jump on the clip's first frame.
GradeWheel _wheel(ResolvedEffect fx, String zone) {
  final mix = fx.intensity.clamp(0.0, 1.0);
  return GradeWheel.fromPosition(
    fx.value('${zone}X') * mix,
    fx.value('${zone}Y') * mix,
  );
}

abstract final class EffectCatalog {
  static final Map<EffectType, EffectSpec> _specs = {
    for (final spec in all) spec.type: spec,
  };

  static EffectSpec? specFor(EffectType type) => _specs[type];

  static List<EffectSpec> byStage(EffectStage stage) =>
      all.where((s) => s.stage == stage).toList();

  /// Everything the effects browser shows, in presentation order.
  static final List<EffectSpec> all = [
    // ── Blur ───────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.blur,
      label: 'Blur',
      description: 'Soften the whole frame.',
      icon: Icons.blur_on_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/gaussian_blur.frag',
      params: const [
        EffectParamSpec(
          key: 'radius',
          label: 'Radius',
          min: 0,
          max: 40,
          defaultValue: 8,
          unit: 'px',
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'gblur',
          parameter: 'sigma',
          // Mirrors the static path exactly: sigma ≈ radius/3.
          valueAt: (fx) => (fx.value('radius', 8) * fx.intensity) / 3,
        ),
      ],
      buildFilters: (fx) {
        final radius = fx.value('radius', 8) * fx.intensity;
        if (radius < 0.3) return const [];
        // gblur's sigma is roughly radius/3 for a visually matched blur.
        return [
          Filter('gblur', {
            'sigma': FilterGraph.formatDouble(radius / 3),
            'steps': radius > 20 ? 3 : 1,
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.motionBlur,
      label: 'Motion blur',
      description: 'Smear frames together along movement.',
      icon: Icons.motion_photos_on_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/motion_blur.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
        EffectParamSpec(
          key: 'angle',
          label: 'Angle',
          min: 0,
          max: 360,
          defaultValue: 0,
          unit: '°',
          isAngle: true,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'tmix',
          parameter: 'frames',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
            return (2 + amount * 6).roundToDouble().clamp(2, 8);
          },
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        // `tmix` averages N consecutive frames — a true temporal smear rather
        // than a directional convolution, which is what motion blur actually
        // is for footage that already contains movement.
        final frames = (2 + amount * 6).round().clamp(2, 8);
        return [Filter('tmix', {'frames': frames})];
      },
    ),

    // ── Light ──────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.glow,
      label: 'Glow',
      description: 'Bloom the highlights.',
      icon: Icons.auto_awesome_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/glow.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
        EffectParamSpec(
          key: 'threshold',
          label: 'Threshold',
          min: 0,
          max: 1,
          defaultValue: 0.6,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'gblur',
          parameter: 'sigma',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
            return 4 + amount * 12;
          },
        ),
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'brightness',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
            return amount * 0.06;
          },
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        // Split → blur one copy → screen-blend it back. `split` inside a chain
        // needs its own labels, so the export engine expands this pattern; here
        // we approximate with a lift on the highlights plus a soft blur, which
        // survives being inlined in a linear chain.
        return [
          Filter('gblur', {'sigma': FilterGraph.formatDouble(4 + amount * 12)}),
          Filter('eq', {
            'brightness': FilterGraph.formatDouble(amount * 0.06),
            'contrast': FilterGraph.formatDouble(1 + amount * 0.12),
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.flash,
      label: 'Flash',
      description: 'Blow the exposure out to white.',
      icon: Icons.flash_on_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/glow.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.7,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'brightness',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.7) * fx.intensity).clamp(0.0, 1.0);
            return amount * 0.5;
          },
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.7) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        return [
          Filter('eq', {
            'brightness': FilterGraph.formatDouble(amount * 0.5),
            'saturation': FilterGraph.formatDouble(1 - amount * 0.4),
          }),
        ];
      },
    ),

    // ── Stylise ────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.vhs,
      label: 'VHS',
      description: 'Tape wobble, scanlines and colour bleed.',
      icon: Icons.videocam_rounded,
      stage: EffectStage.texture,
      shaderAsset: 'shaders/vhs.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.6,
        ),
        EffectParamSpec(
          key: 'scanlines',
          label: 'Scanlines',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
      ],
      commands: [
        // Only the chroma smear animates: `noise` has no command support, so
        // the grain component holds its first-frame value.
        EffectCommandBinding(
          filter: 'chromashift',
          parameter: 'cbh',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.6) * fx.intensity).clamp(0.0, 1.0);
            return (amount * 6).roundToDouble();
          },
        ),
        EffectCommandBinding(
          filter: 'chromashift',
          parameter: 'crh',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.6) * fx.intensity).clamp(0.0, 1.0);
            return -(amount * 4).roundToDouble();
          },
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.6) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        return [
          // Chroma smear: downsample colour, keep luma sharp — the defining
          // artefact of composite video.
          Filter('chromashift', {
            'cbh': (amount * 6).round(),
            'crh': -(amount * 4).round(),
          }),
          Filter('noise', {
            'alls': (amount * 16).round(),
            'allf': 't',
          }),
          Filter('eq', {
            'saturation': FilterGraph.formatDouble(1 - amount * 0.15),
            'contrast': FilterGraph.formatDouble(1 + amount * 0.1),
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.rgbSplit,
      label: 'RGB split',
      description: 'Offset the colour channels.',
      icon: Icons.filter_center_focus_rounded,
      stage: EffectStage.texture,
      shaderAsset: 'shaders/rgb_split.frag',
      params: const [
        EffectParamSpec(
          key: 'offset',
          label: 'Offset',
          min: 0,
          max: 40,
          defaultValue: 8,
          unit: 'px',
        ),
        EffectParamSpec(
          key: 'angle',
          label: 'Angle',
          min: 0,
          max: 360,
          defaultValue: 0,
          unit: '°',
          isAngle: true,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'rgbashift',
          parameter: 'rh',
          valueAt: (fx) =>
              (fx.value('offset', 8) * fx.intensity).roundToDouble(),
        ),
        EffectCommandBinding(
          filter: 'rgbashift',
          parameter: 'bh',
          valueAt: (fx) =>
              -(fx.value('offset', 8) * fx.intensity).roundToDouble(),
        ),
      ],
      buildFilters: (fx) {
        final offset = (fx.value('offset', 8) * fx.intensity).round();
        if (offset == 0) return const [];
        return [
          Filter('rgbashift', {'rh': offset, 'bh': -offset}),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.vintage,
      label: 'Vintage',
      description: 'Faded film stock with warm shadows.',
      icon: Icons.filter_vintage_rounded,
      stage: EffectStage.texture,
      shaderAsset: 'shaders/vintage.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.7,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'saturation',
          valueAt: (fx) {
            final amount =
                (fx.value('amount', 0.7) * fx.intensity).clamp(0.0, 1.0);
            return 1 - amount * 0.35;
          },
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.7) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        return [
          Filter('curves', {
            // Lifted blacks and rolled-off highlights: the look of a print
            // that has been in a drawer for thirty years.
            'r': '0/0.06 0.5/0.55 1/0.95',
            'g': '0/0.04 0.5/0.5 1/0.92',
            'b': '0/0.10 0.5/0.46 1/0.88',
          }),
          Filter('eq', {
            'saturation': FilterGraph.formatDouble(1 - amount * 0.35),
            'contrast': FilterGraph.formatDouble(1 - amount * 0.1),
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.filmGrain,
      label: 'Film grain',
      description: 'Organic sensor-free noise.',
      icon: Icons.grain_rounded,
      stage: EffectStage.texture,
      shaderAsset: 'shaders/film_grain.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.35,
        ),
        EffectParamSpec(
          key: 'size',
          label: 'Size',
          min: 0.5,
          max: 4,
          defaultValue: 1,
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.35) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        return [
          Filter('noise', {
            'alls': (amount * 40).round().clamp(1, 100),
            // `t` = temporal: fresh grain each frame. Without it the noise
            // freezes onto the picture and reads as dirt on the lens.
            'allf': 't+u',
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.vignette,
      label: 'Vignette',
      description: 'Darken the frame edges.',
      icon: Icons.vignette_rounded,
      stage: EffectStage.texture,
      shaderAsset: 'shaders/vintage.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
      ],
      buildFilters: (fx) {
        final amount = (fx.value('amount', 0.5) * fx.intensity).clamp(0.0, 1.0);
        if (amount < 0.02) return const [];
        // `angle` is the aperture: PI/5 is a wide, gentle falloff.
        final angle = 0.1 + amount * 0.55;
        return [
          Filter('vignette', {'angle': FilterGraph.formatDouble(angle)}),
        ];
      },
    ),

    // ── Detail ─────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.sharpen,
      label: 'Sharpen',
      description: 'Crisp up edge detail.',
      icon: Icons.details_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/sharpen.frag',
      params: const [
        EffectParamSpec(
          key: 'amount',
          label: 'Amount',
          min: 0,
          max: 2,
          defaultValue: 0.8,
        ),
      ],
      buildFilters: (fx) {
        final amount = fx.value('amount', 0.8) * fx.intensity;
        if (amount < 0.02) return const [];
        return [
          Filter('unsharp', {
            'luma_msize_x': 5,
            'luma_msize_y': 5,
            'luma_amount': FilterGraph.formatDouble(amount),
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.noiseReduction,
      label: 'Noise reduction',
      description: 'Clean up low-light grain.',
      icon: Icons.cleaning_services_rounded,
      stage: EffectStage.stylise,
      shaderAsset: 'shaders/gaussian_blur.frag',
      params: const [
        EffectParamSpec(
          key: 'strength',
          label: 'Strength',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'hqdn3d',
          parameter: 'luma_spatial',
          valueAt: (fx) =>
              (fx.value('strength', 0.5) * fx.intensity).clamp(0.0, 1.0) * 6,
        ),
        EffectCommandBinding(
          filter: 'hqdn3d',
          parameter: 'chroma_spatial',
          valueAt: (fx) =>
              (fx.value('strength', 0.5) * fx.intensity).clamp(0.0, 1.0) * 5,
        ),
      ],
      buildFilters: (fx) {
        final strength =
            (fx.value('strength', 0.5) * fx.intensity).clamp(0.0, 1.0);
        if (strength < 0.02) return const [];
        // hqdn3d is a temporal+spatial denoiser: far better than a blur
        // because it preserves stationary detail across frames.
        return [
          Filter('hqdn3d', {
            'luma_spatial': FilterGraph.formatDouble(strength * 6),
            'chroma_spatial': FilterGraph.formatDouble(strength * 5),
            'luma_tmp': FilterGraph.formatDouble(strength * 8),
            'chroma_tmp': FilterGraph.formatDouble(strength * 7),
          }),
        ];
      },
    ),

    // ── Retouch ────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.faceRetouch,
      label: 'Retouch',
      description: 'Softens skin without flattening eyes, hair or the frame.',
      icon: Icons.face_retouching_natural_rounded,
      stage: EffectStage.color,
      shaderAsset: 'shaders/retouch.frag',
      params: const [
        EffectParamSpec(
          key: 'smooth',
          label: 'Smoothing',
          min: 0,
          max: 1,
          defaultValue: 0.5,
        ),
        EffectParamSpec(
          key: 'glow',
          label: 'Glow',
          min: 0,
          max: 1,
          defaultValue: 0.2,
        ),
        EffectParamSpec(
          key: 'clarity',
          label: 'Eye clarity',
          min: 0,
          max: 1,
          defaultValue: 0.3,
        ),
      ],
      buildFilters: (_) => const [],
      buildGraph: RetouchCompiler.build,
    ),

    // ── Colour ─────────────────────────────────────────────────────────
    EffectSpec(
      type: EffectType.cinematicLut,
      label: 'Cinematic LUT',
      description: 'Apply a 3D colour lookup table.',
      icon: Icons.palette_rounded,
      stage: EffectStage.color,
      shaderAsset: 'shaders/lut3d.frag',
      params: const [
        EffectParamSpec(
          key: 'mix',
          label: 'Strength',
          min: 0,
          max: 1,
          defaultValue: 1,
        ),
      ],
      buildFilters: (fx) {
        final path = fx.string('lut');
        if (path == null || path.isEmpty) return const [];
        return [
          Filter('lut3d', {
            'file': FilterGraph.escapePath(path),
            'interp': 'tetrahedral',
          }),
        ];
      },
    ),

    EffectSpec(
      type: EffectType.colorAdjust,
      label: 'Adjust',
      description: 'Brightness, contrast, saturation and temperature.',
      icon: Icons.tune_rounded,
      stage: EffectStage.color,
      shaderAsset: 'shaders/passthrough.frag',
      params: const [
        EffectParamSpec(
          key: 'brightness',
          label: 'Brightness',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'contrast',
          label: 'Contrast',
          min: 0,
          max: 3,
          defaultValue: 1,
        ),
        EffectParamSpec(
          key: 'saturation',
          label: 'Saturation',
          min: 0,
          max: 3,
          defaultValue: 1,
        ),
        EffectParamSpec(
          key: 'gamma',
          label: 'Gamma',
          min: 0.1,
          max: 3,
          defaultValue: 1,
        ),
        EffectParamSpec(
          key: 'temperature',
          label: 'Temperature',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'brightness',
          valueAt: (fx) => fx.value('brightness') * fx.intensity,
        ),
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'contrast',
          valueAt: (fx) =>
              1 + (fx.value('contrast', 1) - 1) * fx.intensity,
        ),
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'saturation',
          valueAt: (fx) =>
              1 + (fx.value('saturation', 1) - 1) * fx.intensity,
        ),
        EffectCommandBinding(
          filter: 'eq',
          parameter: 'gamma',
          valueAt: (fx) => 1 + (fx.value('gamma', 1) - 1) * fx.intensity,
        ),
      ],
      buildFilters: (fx) {
        final mix = fx.intensity;
        final brightness = fx.value('brightness') * mix;
        final contrast = 1 + (fx.value('contrast', 1) - 1) * mix;
        final saturation = 1 + (fx.value('saturation', 1) - 1) * mix;
        final gamma = 1 + (fx.value('gamma', 1) - 1) * mix;
        final temperature = fx.value('temperature') * mix;

        final filters = <Filter>[];
        final isNeutral = brightness.abs() < 0.001 &&
            (contrast - 1).abs() < 0.001 &&
            (saturation - 1).abs() < 0.001 &&
            (gamma - 1).abs() < 0.001;
        if (!isNeutral) {
          filters.add(
            Filter('eq', {
              'brightness': FilterGraph.formatDouble(brightness),
              'contrast': FilterGraph.formatDouble(contrast),
              'saturation': FilterGraph.formatDouble(saturation),
              'gamma': FilterGraph.formatDouble(gamma),
            }),
          );
        }
        if (temperature.abs() > 0.001) {
          // Warm = lift red, drop blue. colorbalance works in shadows/mids/
          // highlights; touching midtones alone keeps skin tones sane.
          filters.add(
            Filter('colorbalance', {
              'rm': FilterGraph.formatDouble(temperature * 0.3),
              'bm': FilterGraph.formatDouble(-temperature * 0.3),
            }),
          );
        }
        return filters;
      },
    ),

    EffectSpec(
      type: EffectType.colorGrade,
      label: 'Grade',
      description:
          'White balance, tone and three-way colour wheels — the full grade.',
      icon: Icons.gradient_rounded,
      stage: EffectStage.color,
      shaderAsset: 'shaders/grade.frag',
      params: const [
        EffectParamSpec(
          key: 'warmth',
          label: 'Warmth',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'tint',
          label: 'Tint',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'contrast',
          label: 'Contrast',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'pivot',
          label: 'Pivot',
          min: 0.2,
          max: 0.8,
          defaultValue: 0.5,
        ),
        EffectParamSpec(
          key: 'shadows',
          label: 'Shadows',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'highlights',
          label: 'Highlights',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(key: 'liftX', label: 'Lift ×', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(key: 'liftY', label: 'Lift Y', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(key: 'gammaX', label: 'Gamma ×', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(key: 'gammaY', label: 'Gamma Y', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(key: 'gainX', label: 'Gain ×', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(key: 'gainY', label: 'Gain Y', min: -1, max: 1, defaultValue: 0),
        EffectParamSpec(
          key: 'vibrance',
          label: 'Vibrance',
          min: -1,
          max: 1,
          defaultValue: 0,
        ),
        EffectParamSpec(
          key: 'saturation',
          label: 'Saturation',
          min: 0,
          max: 2,
          defaultValue: 1,
        ),
      ],
      buildFilters: GradeCompiler.build,
      commands: [
        EffectCommandBinding(
          filter: 'colortemperature',
          parameter: 'temperature',
          valueAt: (fx) => GradeCompiler.kelvinFor(
            fx.value('warmth').clamp(-1.0, 1.0) * fx.intensity,
          ),
        ),
        EffectCommandBinding(
          filter: 'colorchannelmixer',
          parameter: 'gg',
          valueAt: (fx) =>
              1 + fx.value('tint').clamp(-1.0, 1.0) * fx.intensity * 0.12,
        ),
        EffectCommandBinding(
          filter: 'colorchannelmixer',
          parameter: 'rr',
          valueAt: (fx) =>
              1 - fx.value('tint').clamp(-1.0, 1.0) * fx.intensity * 0.06,
        ),
        EffectCommandBinding(
          filter: 'colorchannelmixer',
          parameter: 'bb',
          valueAt: (fx) =>
              1 - fx.value('tint').clamp(-1.0, 1.0) * fx.intensity * 0.06,
        ),
        // The nine wheel channels. Written out rather than generated because a
        // binding is a const value, and the alternative — a loop building them
        // at startup — trades a readable list for a clever one.
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'rs',
          valueAt: (fx) => _wheel(fx, 'lift').r,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'gs',
          valueAt: (fx) => _wheel(fx, 'lift').g,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'bs',
          valueAt: (fx) => _wheel(fx, 'lift').b,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'rm',
          valueAt: (fx) => _wheel(fx, 'gamma').r,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'gm',
          valueAt: (fx) => _wheel(fx, 'gamma').g,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'bm',
          valueAt: (fx) => _wheel(fx, 'gamma').b,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'rh',
          valueAt: (fx) => _wheel(fx, 'gain').r,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'gh',
          valueAt: (fx) => _wheel(fx, 'gain').g,
        ),
        EffectCommandBinding(
          filter: 'colorbalance',
          parameter: 'bh',
          valueAt: (fx) => _wheel(fx, 'gain').b,
        ),
        EffectCommandBinding(
          filter: 'vibrance',
          parameter: 'intensity',
          valueAt: (fx) =>
              fx.value('vibrance').clamp(-1.0, 1.0) * fx.intensity * 0.8,
        ),
        EffectCommandBinding(
          filter: 'hue',
          parameter: 's',
          valueAt: (fx) =>
              1 + (fx.value('saturation', 1) - 1) * fx.intensity,
        ),
      ],
      stringCommands: [
        EffectStringCommandBinding(
          filter: 'curves',
          parameter: 'all',
          valueAt: (fx) => GradeCompiler.tonePoints(
            contrast: fx.value('contrast').clamp(-1.0, 1.0) * fx.intensity,
            pivot: fx.value('pivot', 0.5).clamp(0.15, 0.85),
            shadows: fx.value('shadows').clamp(-1.0, 1.0) * fx.intensity,
            highlights: fx.value('highlights').clamp(-1.0, 1.0) * fx.intensity,
          ),
        ),
      ],
    ),

    EffectSpec(
      type: EffectType.stabilise,
      label: 'Stabilise',
      description: 'Smooths out camera shake. Analyses the clip first.',
      icon: Icons.videocam_rounded,
      stage: EffectStage.color,
      shaderAsset: null,
      requiresPreRender: true,
      params: const [
        EffectParamSpec(
          key: 'smoothing',
          label: 'Smoothing',
          min: 1,
          max: 60,
          defaultValue: 10,
          unit: 'f',
        ),
      ],
      // Emitted by the pre-render pass, not inline — see TimelineCompiler.
      buildFilters: (fx) => const [],
    ),

    EffectSpec(
      type: EffectType.chromaKey,
      label: 'Chroma key',
      description: 'Knock out a background colour.',
      icon: Icons.layers_clear_rounded,
      stage: EffectStage.color,
      shaderAsset: 'shaders/passthrough.frag',
      params: const [
        EffectParamSpec(
          key: 'similarity',
          label: 'Similarity',
          min: 0.01,
          max: 1,
          defaultValue: 0.3,
        ),
        EffectParamSpec(
          key: 'blend',
          label: 'Edge blend',
          min: 0,
          max: 1,
          defaultValue: 0.1,
        ),
      ],
      commands: [
        EffectCommandBinding(
          filter: 'chromakey',
          parameter: 'similarity',
          valueAt: (fx) => fx.value('similarity', 0.3),
        ),
        EffectCommandBinding(
          filter: 'chromakey',
          parameter: 'blend',
          valueAt: (fx) => fx.value('blend', 0.1),
        ),
      ],
      buildFilters: (fx) {
        final key = fx.string('key') ?? '0x00FF00';
        return [
          Filter('chromakey', {
            'color': key,
            'similarity': FilterGraph.formatDouble(fx.value('similarity', 0.3)),
            'blend': FilterGraph.formatDouble(fx.value('blend', 0.1)),
          }),
        ];
      },
    ),
  ];

  /// Expands a clip's effect list into a flat filter chain, in stage order.
  static List<Filter> buildChain(List<ResolvedEffect> effects) {
    final ordered = List<ResolvedEffect>.of(effects)
      ..sort(
        (a, b) => _stageOf(a.type).order.compareTo(_stageOf(b.type).order),
      );
    final filters = <Filter>[];
    for (final effect in ordered) {
      if (effect.isNoOp) continue;
      final spec = _specs[effect.type];
      if (spec == null) continue;
      filters.addAll(spec.buildFilters(effect));
    }
    return filters;
  }

  /// Sort key for the stage an effect belongs to.
  static int stageOrderOf(EffectType type) => _stageOf(type).order;

  static EffectStage _stageOf(EffectType type) =>
      _specs[type]?.stage ?? EffectStage.stylise;

  const EffectCatalog._();
}
