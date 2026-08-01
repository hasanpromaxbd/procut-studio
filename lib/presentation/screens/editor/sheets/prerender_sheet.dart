/// Pre-render: find the stretches the preview cannot play, and render them.
///
/// The analysis is [PrerenderPlanner]'s; the rendering is ordinary range
/// export. This sheet is the join between them, and the place the trade is
/// stated plainly — pre-rendering spends storage and battery to buy smooth
/// playback, and the user should be the one deciding that.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/export_range.dart';
import '../../../../domain/entities/export_settings.dart';
import '../../../../engine/render/prerender_planner.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/export_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class PrerenderSheet extends ConsumerWidget {
  const PrerenderSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final progress = ref.watch(exportControllerProvider);
    final theme = Theme.of(context);
    if (editor == null) return const SizedBox.shrink();

    final spans = PrerenderPlanner.plan(editor.timeline);
    final total = PrerenderPlanner.totalDuration(spans);

    return ToolSheet(
      title: 'Smooth playback',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spans.isEmpty)
            Text(
              'Nothing here should trouble playback. Pre-rendering a timeline '
              'the preview can already handle would cost storage and battery '
              'for nothing.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            Text(
              '${spans.length} stretch(es), ${TimeUtils.formatShort(total)} in '
              'total, are heavier than the preview can play smoothly.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Spacing.sm),
            for (final span in spans)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.speed_rounded, size: 18),
                title: Text(
                  '${TimeUtils.formatShort(span.start)} – '
                  '${TimeUtils.formatShort(span.end)}',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  '${span.reason} · about '
                  '${span.cost.toStringAsFixed(1)}× real time',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: TextButton(
                  onPressed: progress != null && !progress.isTerminal
                      ? null
                      : () => _render(ref, span),
                  child: const Text('Render'),
                ),
                onTap: () => ref
                    .read(playheadControllerProvider.notifier)
                    .seek(span.start),
              ),

            const SizedBox(height: Spacing.sm),
            Text(
              'Rendering a stretch writes it out at export quality. The edit '
              'is untouched — this only produces a file you can watch to '
              'judge the timing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          if (progress != null && !progress.isTerminal) ...[
            const SizedBox(height: Spacing.md),
            LinearProgressIndicator(
              value: progress.progress <= 0 ? null : progress.progress,
            ),
          ],
        ],
      ),
    );
  }

  void _render(WidgetRef ref, PrerenderSpan span) {
    final editor = ref.read(editorControllerProvider(projectId));
    if (editor == null) return;

    unawaited(
      ref.read(exportControllerProvider.notifier).start(
        editor.project,
        // Preview quality, not delivery quality: this is watched once to
        // check the timing, and a 4K master would take longer to make than
        // the stretch takes to watch.
        const ExportSettings(resolution: ExportResolution.p720),
        range: ExportRange(start: span.start, end: span.end),
      ),
    );
  }
}
