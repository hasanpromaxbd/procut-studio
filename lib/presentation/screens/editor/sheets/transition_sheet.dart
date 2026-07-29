/// Transition picker for the join after the selected clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/transition.dart';
import '../../../../engine/transitions/transition_catalog.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class TransitionSheet extends ConsumerStatefulWidget {
  const TransitionSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<TransitionSheet> createState() => _TransitionSheetState();
}

class _TransitionSheetState extends ConsumerState<TransitionSheet> {
  Duration _duration = AppConstants.defaultTransitionDuration;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );
    final theme = Theme.of(context);

    final clipId = editor?.selectedClipId;
    final found = clipId == null ? null : editor!.timeline.findClip(clipId);
    final clip = found?.$2;

    if (clip == null) {
      return const ToolSheet(
        title: 'Transition',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Text('Select the clip *before* the cut you want to soften.'),
        ),
      );
    }

    final current = clip.outTransition;

    return ToolSheet(
      title: 'Transition',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Applies to the cut at the end of this clip. Adding one overlaps '
            'the two clips, so the timeline gets a little shorter.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SectionHeader(title: 'Style'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: Spacing.sm,
            mainAxisSpacing: Spacing.sm,
            childAspectRatio: 0.85,
            children: [
              _TransitionTile(
                icon: Icons.block_rounded,
                label: 'None',
                selected: current == null || !current.isActive,
                onTap: () =>
                    controller.setTransition(clip.id, TransitionType.none),
              ),
              for (final spec in TransitionCatalog.all)
                _TransitionTile(
                  icon: spec.icon,
                  label: spec.label,
                  selected: current?.type == spec.type,
                  slow: !spec.isExactNatively,
                  onTap: () => controller.setTransition(
                    clip.id,
                    spec.type,
                    duration: _duration,
                  ),
                ),
            ],
          ),
          const SectionHeader(title: 'Duration'),
          LabeledSlider(
            label: 'Length',
            value: (current?.duration ?? _duration).inMilliseconds.toDouble(),
            min: 100,
            max: AppConstants.maxTransitionDuration.inMilliseconds.toDouble(),
            divisions: 49,
            formatter: (v) => '${(v / 1000).toStringAsFixed(2)}s',
            onChanged: (value) {
              final duration = Duration(milliseconds: value.round());
              setState(() => _duration = duration);
              if (current != null && current.isActive) {
                controller.setTransition(
                  clip.id,
                  current.type,
                  duration: duration,
                );
              }
            },
          ),
          if (current != null && TransitionCatalog.isExpensive(current))
            Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Row(
                  children: [
                    Icon(
                      Icons.hourglass_bottom_rounded,
                      size: 18,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'This one has no hardware-accelerated equivalent, so '
                        'it is rendered pixel by pixel and will slow the '
                        'export down. You can switch to the fast approximation '
                        'on the export screen.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TransitionTile extends StatelessWidget {
  const _TransitionTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.slow = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool slow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
      child: AnimatedContainer(
        duration: Motion.fast,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : theme.colorScheme.surfaceContainer,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (slow)
              Positioned(
                right: 4,
                top: 4,
                child: Tooltip(
                  message: 'Slower to export',
                  child: Icon(
                    Icons.hourglass_empty_rounded,
                    size: 11,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
