/// Effect browser and parameter inspector.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/effect.dart';
import '../../../../engine/effects/effect_catalog.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/eyedropper_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class EffectsSheet extends ConsumerWidget {
  const EffectsSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);

    final found = editor?.selectedClipId == null
        ? null
        : editor!.timeline.findClip(editor.selectedClipId!);
    final clip = found?.$2;

    if (clip == null) {
      return const ToolSheet(
        title: 'Effects',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Text('Select a clip to add effects to it.'),
        ),
      );
    }

    return ToolSheet(
      title: 'Effects',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (clip.effects.isNotEmpty) ...[
            const SectionHeader(title: 'Applied'),
            for (final effect in clip.effects)
              _AppliedEffectTile(
                effect: effect,
                onChanged: controller.updateEffect,
                onRemove: () => controller.removeEffect(effect.id),
                onPickKeyColour: effect.type == EffectType.chromaKey
                    ? () {
                        // Arm the eyedropper and get out of the way — the
                        // sheet covers the preview the user needs to tap.
                        ref.read(eyedropperProvider.notifier).begin(effect.id);
                        Navigator.of(context).pop();
                      }
                    : null,
              ),
          ],
          const SectionHeader(title: 'Add an effect'),
          for (final stage in EffectStage.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.xs),
              child: Text(
                switch (stage) {
                  EffectStage.color => 'Colour',
                  EffectStage.stylise => 'Stylise',
                  EffectStage.texture => 'Texture',
                },
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final spec in EffectCatalog.byStage(stage))
                  ActionChip(
                    avatar: Icon(spec.icon, size: 16),
                    label: Text(spec.label),
                    tooltip: spec.description,
                    onPressed: () => controller.addEffect(spec.type),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.lg),
          Text(
            'Effects are applied colour → stylise → texture, the same order the '
            'exporter uses, so the preview matches the render.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppliedEffectTile extends StatelessWidget {
  const _AppliedEffectTile({
    required this.effect,
    required this.onChanged,
    required this.onRemove,
    this.onPickKeyColour,
  });

  final Effect effect;
  final ValueChanged<Effect> onChanged;
  final VoidCallback onRemove;

  /// Only set for chroma key — arms the preview eyedropper.
  final VoidCallback? onPickKeyColour;

  @override
  Widget build(BuildContext context) {
    final spec = EffectCatalog.specFor(effect.type);
    final theme = Theme.of(context);
    if (spec == null) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(spec.icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(spec.label, style: theme.textTheme.titleSmall),
                ),
                Switch(
                  value: effect.enabled,
                  onChanged: (value) =>
                      onChanged(effect.copyWith(enabled: value)),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: onRemove,
                  tooltip: 'Remove',
                ),
              ],
            ),
            if (effect.enabled) ...[
              LabeledSlider(
                label: 'Strength',
                value: effect.intensity.staticValue,
                min: 0,
                max: 1,
                formatter: (v) => '${(v * 100).round()}%',
                onChanged: (value) => onChanged(
                  effect.copyWith(
                    intensity: effect.intensity.withStatic(value),
                  ),
                ),
              ),
              if (onPickKeyColour != null) ...[
                Builder(
                  builder: (context) {
                    final key = effect.stringParams['key'];
                    final colour = key == null
                        ? null
                        : int.tryParse(key.replaceFirst('0x', ''), radix: 16);
                    return Row(
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: colour == null
                                ? const Color(0xFF00FF00)
                                : Color(0xFF000000 | colour),
                            borderRadius: const BorderRadius.all(
                              Radius.circular(6),
                            ),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            key ?? '0x00ff00 (default green)',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: onPickKeyColour,
                          icon: const Icon(Icons.colorize_rounded, size: 18),
                          label: const Text('Pick'),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: Spacing.sm),
              ],
              for (final param in spec.params)
                LabeledSlider(
                  label: param.label,
                  value: effect.param(param.key, fallback: param.defaultValue),
                  min: param.min,
                  max: param.max,
                  formatter: (v) => param.unit.isEmpty
                      ? v.toStringAsFixed(2)
                      : '${v.toStringAsFixed(param.max > 10 ? 0 : 2)}${param.unit}',
                  onChanged: (value) =>
                      onChanged(effect.withParamValue(param.key, value)),
                  onReset: () =>
                      onChanged(effect.withParamValue(param.key, param.defaultValue)),
                ),
              if (effect.type == EffectType.motionBlur)
                Text(
                  'Preview shows a directional smear; the export averages real '
                  'neighbouring frames, which looks slightly softer.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
