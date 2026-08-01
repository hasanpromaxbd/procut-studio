/// Named starting points for a grade.
///
/// A look is not a filter and not a LUT — it is a set of positions for the
/// grade's own controls. That matters: after applying one, every wheel and
/// slider shows where it landed and can be moved from there. A LUT is opaque
/// and a preset that hides its own values is the same trap in a friendlier
/// wrapper.
///
/// The values are deliberately restrained. A look that announces itself on the
/// first frame is a look you delete on the second pass.
library;

import '../../domain/entities/effect.dart';

class GradeLook {
  const GradeLook({
    required this.id,
    required this.label,
    required this.description,
    required this.values,
  });

  final String id;
  final String label;
  final String description;

  /// Parameter positions, keyed as in the [EffectType.colorGrade] spec.
  final Map<String, double> values;
}

abstract final class GradeLooks {
  static const neutral = GradeLook(
    id: 'neutral',
    label: 'Neutral',
    description: 'Every control back to zero.',
    values: {
      'warmth': 0,
      'tint': 0,
      'contrast': 0,
      'pivot': 0.5,
      'shadows': 0,
      'highlights': 0,
      'liftX': 0,
      'liftY': 0,
      'gammaX': 0,
      'gammaY': 0,
      'gainX': 0,
      'gainY': 0,
      'vibrance': 0,
      'saturation': 1,
    },
  );

  static const all = <GradeLook>[
    neutral,
    GradeLook(
      id: 'teal_orange',
      label: 'Teal & orange',
      description: 'Cool shadows, warm skin. The blockbuster split.',
      values: {
        'warmth': 0.12,
        'tint': 0,
        'contrast': 0.35,
        'pivot': 0.45,
        'shadows': -0.1,
        'highlights': 0.05,
        // Shadows pushed to teal, highlights to amber — the split is what
        // makes skin read as warm without warming the whole frame.
        'liftX': -0.45,
        'liftY': -0.28,
        'gammaX': 0,
        'gammaY': 0,
        'gainX': 0.3,
        'gainY': 0.34,
        'vibrance': 0.2,
        'saturation': 1.05,
      },
    ),
    GradeLook(
      id: 'clean',
      label: 'Clean',
      description: 'Neutral and bright. What a good camera would have given.',
      values: {
        'warmth': 0.04,
        'tint': 0,
        'contrast': 0.18,
        'pivot': 0.5,
        'shadows': 0.08,
        'highlights': 0.06,
        'liftX': 0,
        'liftY': 0,
        'gammaX': 0,
        'gammaY': 0,
        'gainX': 0,
        'gainY': 0,
        'vibrance': 0.25,
        'saturation': 1,
      },
    ),
    GradeLook(
      id: 'film',
      label: 'Film',
      description: 'Lifted blacks, soft shoulder, gentle green in the shadows.',
      values: {
        'warmth': 0.08,
        'tint': -0.05,
        'contrast': 0.22,
        'pivot': 0.42,
        // The lifted black is the whole point: film never reaches zero.
        'shadows': 0.28,
        'highlights': -0.12,
        'liftX': -0.12,
        'liftY': 0.22,
        'gammaX': 0,
        'gammaY': 0,
        'gainX': 0.1,
        'gainY': 0.12,
        'vibrance': -0.05,
        'saturation': 0.92,
      },
    ),
    GradeLook(
      id: 'moonlight',
      label: 'Moonlight',
      description: 'Cool, low and blue — night that still reads as night.',
      values: {
        'warmth': -0.35,
        'tint': 0.05,
        'contrast': 0.3,
        'pivot': 0.4,
        'shadows': -0.2,
        'highlights': -0.15,
        'liftX': 0.15,
        'liftY': -0.4,
        'gammaX': 0.08,
        'gammaY': -0.2,
        'gainX': 0,
        'gainY': -0.15,
        'vibrance': -0.1,
        'saturation': 0.85,
      },
    ),
    GradeLook(
      id: 'golden',
      label: 'Golden hour',
      description: 'Warm, soft and slightly hazy. Late afternoon on demand.',
      values: {
        'warmth': 0.4,
        'tint': -0.08,
        'contrast': 0.12,
        'pivot': 0.55,
        'shadows': 0.18,
        'highlights': 0.12,
        'liftX': 0.1,
        'liftY': 0.18,
        'gammaX': 0.12,
        'gammaY': 0.1,
        'gainX': 0.2,
        'gainY': 0.26,
        'vibrance': 0.15,
        'saturation': 1.05,
      },
    ),
    GradeLook(
      id: 'bleach',
      label: 'Bleach',
      description: 'Hard contrast, drained colour. Grim on purpose.',
      values: {
        'warmth': -0.05,
        'tint': 0,
        'contrast': 0.6,
        'pivot': 0.5,
        'shadows': -0.25,
        'highlights': 0.2,
        'liftX': 0,
        'liftY': -0.1,
        'gammaX': 0,
        'gammaY': 0,
        'gainX': 0,
        'gainY': 0.08,
        'vibrance': -0.3,
        'saturation': 0.55,
      },
    ),
  ];

  static GradeLook? byId(String id) {
    for (final look in all) {
      if (look.id == id) return look;
    }
    return null;
  }
}
