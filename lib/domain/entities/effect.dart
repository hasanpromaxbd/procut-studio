/// Effects applied to a clip.
///
/// An [Effect] is pure data: a type plus named scalar parameters, each of which
/// may be keyframed. It knows nothing about how it is rendered — the preview
/// path resolves it to a GPU fragment shader and the export path resolves it to
/// an FFmpeg filter, both from the same parameter set. See
/// `engine/effects/effect_catalog.dart`.
library;

import 'package:flutter/foundation.dart';

import 'keyframe.dart';

enum EffectType {
  // ── Blur family ──────────────────────────────────────────────────────
  blur('blur'),
  motionBlur('motion_blur'),

  // ── Light ────────────────────────────────────────────────────────────
  glow('glow'),
  flash('flash'),

  // ── Stylise ──────────────────────────────────────────────────────────
  vhs('vhs'),
  rgbSplit('rgb_split'),
  vintage('vintage'),
  filmGrain('film_grain'),

  // ── Detail ───────────────────────────────────────────────────────────
  sharpen('sharpen'),
  noiseReduction('noise_reduction'),

  // ── Retouch ──────────────────────────────────────────────────────────
  faceRetouch('face_retouch'),

  // ── Colour ───────────────────────────────────────────────────────────
  cinematicLut('cinematic_lut'),
  colorAdjust('color_adjust'),
  colorGrade('color_grade'),
  vignette('vignette'),
  chromaKey('chroma_key'),

  /// Two-pass `vidstab`. Cannot be expressed inline — the compiler lifts it
  /// into a pre-render step, which is why it has no filter emitter.
  stabilise('stabilise');

  const EffectType(this.id);
  final String id;

  static EffectType fromId(String? id) => EffectType.values.firstWhere(
    (e) => e.id == id,
    orElse: () => EffectType.colorAdjust,
  );
}

/// Where an effect sits in the render order. Applied low-to-high, so a LUT
/// grades the picture *before* grain is laid over it — which is the order a
/// real finishing pipeline uses.
enum EffectStage {
  /// Colour correction and grading.
  color(0),

  /// Geometry-independent stylisation (blur, sharpen, glow).
  stylise(1),

  /// Texture laid on top (grain, vignette, VHS artefacts).
  texture(2);

  const EffectStage(this.order);
  final int order;
}

@immutable
class Effect {
  const Effect({
    required this.id,
    required this.type,
    this.enabled = true,
    this.params = const {},
    this.stringParams = const {},
    this.intensity = const AnimatableDouble.constant(1),
  });

  final String id;
  final EffectType type;
  final bool enabled;

  /// Named scalar parameters — `radius`, `amount`, `angle`, … Each is
  /// animatable, which is what makes "blur ramps up over two seconds" possible
  /// without a special case.
  final Map<String, AnimatableDouble> params;

  /// Non-numeric parameters, e.g. the LUT file path or a hex key colour.
  final Map<String, String> stringParams;

  /// Global wet/dry mix for the whole effect, 0..1.
  final AnimatableDouble intensity;

  bool get isAnimated =>
      intensity.isAnimated || params.values.any((p) => p.isAnimated);

  double param(String key, {double fallback = 0}) =>
      params[key]?.staticValue ?? fallback;

  double paramAt(String key, Duration time, {double fallback = 0}) =>
      params[key]?.valueAt(time) ?? fallback;

  double intensityAt(Duration time) => intensity.valueAt(time).clamp(0.0, 1.0);

  /// Every parameter flattened at [time] — the shape both renderers consume.
  ResolvedEffect resolveAt(Duration time) => ResolvedEffect(
    type: type,
    intensity: intensityAt(time),
    values: {
      for (final entry in params.entries) entry.key: entry.value.valueAt(time),
    },
    strings: stringParams,
  );

  Effect copyWith({
    String? id,
    EffectType? type,
    bool? enabled,
    Map<String, AnimatableDouble>? params,
    Map<String, String>? stringParams,
    AnimatableDouble? intensity,
  }) => Effect(
    id: id ?? this.id,
    type: type ?? this.type,
    enabled: enabled ?? this.enabled,
    params: params ?? this.params,
    stringParams: stringParams ?? this.stringParams,
    intensity: intensity ?? this.intensity,
  );

  Effect withParam(String key, AnimatableDouble value) => copyWith(
    params: {...params, key: value},
  );

  Effect withParamValue(String key, double value) => copyWith(
    params: {
      ...params,
      key: (params[key] ?? AnimatableDouble.constant(value)).withStatic(value),
    },
  );

  Effect withStringParam(String key, String value) => copyWith(
    stringParams: {...stringParams, key: value},
  );

  Effect timeScaled(double factor) => copyWith(
    intensity: intensity.timeScaled(factor),
    params: {
      for (final e in params.entries) e.key: e.value.timeScaled(factor),
    },
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.id,
    if (!enabled) 'off': true,
    if (params.isNotEmpty)
      'params': {for (final e in params.entries) e.key: e.value.toJson()},
    if (stringParams.isNotEmpty) 'strings': stringParams,
    'intensity': intensity.toJson(),
  };

  factory Effect.fromJson(Map<String, dynamic> json) => Effect(
    id: json['id'] as String,
    type: EffectType.fromId(json['type'] as String?),
    enabled: !(json['off'] as bool? ?? false),
    params: ((json['params'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k as String, AnimatableDouble.fromJson(v)),
    ),
    stringParams:
        ((json['strings'] as Map?) ?? const {}).cast<String, String>(),
    intensity: AnimatableDouble.fromJson(json['intensity'], fallback: 1),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Effect && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Effect(${type.id}${enabled ? '' : ', off'})';
}

/// An [Effect] with every animated parameter evaluated at one instant.
@immutable
class ResolvedEffect {
  const ResolvedEffect({
    required this.type,
    required this.intensity,
    required this.values,
    this.strings = const {},
  });

  final EffectType type;
  final double intensity;
  final Map<String, double> values;
  final Map<String, String> strings;

  double value(String key, [double fallback = 0]) => values[key] ?? fallback;
  String? string(String key) => strings[key];

  /// Below this the effect is a no-op and both renderers skip it entirely.
  bool get isNoOp => intensity <= 0.001;
}
