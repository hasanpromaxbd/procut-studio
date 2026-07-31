/// Effect browser and parameter inspector.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/effect.dart';
import '../../../../domain/entities/track.dart';
import '../../../../engine/effects/effect_catalog.dart';
import '../../../../engine/effects/lut_library.dart';
import '../../../../engine/effects/shot_matcher.dart';
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
          const SectionHeader(title: 'Match another shot'),
          ShotMatchTile(projectId: projectId),

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
              if (effect.type == EffectType.cinematicLut) ...[
                _LutPicker(effect: effect, onChanged: onChanged),
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


/// Choose a look, or bring your own `.cube`.
class _LutPicker extends ConsumerStatefulWidget {
  const _LutPicker({required this.effect, required this.onChanged});

  final Effect effect;
  final ValueChanged<Effect> onChanged;

  @override
  ConsumerState<_LutPicker> createState() => _LutPickerState();
}

class _LutPickerState extends ConsumerState<_LutPicker> {
  List<LutEntry>? _luts;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(lutLibraryProvider).list().then((luts) {
        if (mounted) setState(() => _luts = luts);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final luts = _luts;
    final selected = widget.effect.stringParams['lut'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (luts == null)
          const LinearProgressIndicator()
        else
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final lut in luts)
                ChoiceChip(
                  selected: selected == lut.path,
                  label: Text(lut.name),
                  avatar: lut.bundled
                      ? null
                      : const Icon(Icons.folder_rounded, size: 14),
                  onSelected: (_) => widget.onChanged(
                    widget.effect.withStringParam('lut', lut.path),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Import .cube'),
                onPressed: () => unawaited(_import()),
              ),
            ],
          ),
        if (selected == null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              'Pick a look — without one this effect does nothing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final path = picked?.files.firstOrNull?.path;
    if (path == null || !mounted) return;

    final result = await ref.read(lutLibraryProvider).import(path);
    if (!mounted) return;
    result.fold(
      (entry) {
        widget.onChanged(widget.effect.withStringParam('lut', entry.path));
        setState(() => _luts = [...?_luts, entry]);
      },
      (failure) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message))),
    );
  }
}


/// Matches the selected shot to a neighbour's exposure and colour.
///
/// Shows what it will do before doing it: a colour change nobody asked for is
/// worse than one that took two taps.
class ShotMatchTile extends ConsumerStatefulWidget {
  const ShotMatchTile({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ShotMatchTile> createState() => _ShotMatchTileState();
}

class _ShotMatchTileState extends ConsumerState<ShotMatchTile> {
  bool _measuring = false;
  ShotMatch? _proposal;
  double _distance = 0;
  String? _referenceId;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);

    final selectedId = editor?.selectedClipId;
    final neighbours = <Clip>[
      for (final track in editor?.timeline.tracks ?? const <Track>[])
        for (final clip in track.clips)
          if (clip is MediaClip && clip is! ImageClip && clip.id != selectedId)
            clip,
    ]..sort((a, b) => a.start.compareTo(b.start));

    if (selectedId == null || neighbours.isEmpty) {
      return Text(
        'Select a clip, with at least one other on the timeline, to match '
        'their colour.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final proposal = _proposal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Matches exposure and colour cast to another shot. It cannot copy a '
          'grade — four numbers cannot express a look.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Spacing.sm),
        DropdownButtonFormField<String>(
          initialValue: _referenceId ?? neighbours.first.id,
          decoration: const InputDecoration(
            labelText: 'Match to',
            isDense: true,
          ),
          items: [
            for (final clip in neighbours)
              DropdownMenuItem(
                value: clip.id,
                child: Text(
                  '${TimeUtils.formatShort(clip.start)} · '
                  '${clip.label ?? clip.kind.id}',
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _referenceId = value;
            _proposal = null;
          }),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _measuring ? null : () => unawaited(_measure(neighbours)),
              icon: _measuring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.compare_rounded),
              label: Text(_measuring ? 'Measuring…' : 'Compare'),
            ),
            if (proposal != null) ...[
              const SizedBox(width: Spacing.sm),
              FilledButton(
                onPressed: proposal.isNegligible
                    ? null
                    : () {
                        ref
                            .read(
                              editorControllerProvider(
                                widget.projectId,
                              ).notifier,
                            )
                            .applyShotMatch(proposal);
                        setState(() => _proposal = null);
                      },
                child: const Text('Apply'),
              ),
            ],
          ],
        ),
        if (proposal != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(proposal.describe(), style: theme.textTheme.bodyMedium),
          if (_distance > 0.5)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                'These shots are very different — the match is clamped, so it '
                'will get closer without matching exactly.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _measure(List<Clip> neighbours) async {
    setState(() => _measuring = true);
    try {
      final result = await ref
          .read(editorControllerProvider(widget.projectId).notifier)
          .proposeShotMatch(_referenceId ?? neighbours.first.id);
      if (!mounted) return;
      setState(() {
        _proposal = result?.match;
        _distance = result?.distance ?? 0;
      });
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }
}
