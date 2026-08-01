/// Multicam: add angles, sync them by sound, cut between them while watching.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/multicam_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class MulticamSheet extends ConsumerWidget {
  const MulticamSheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final multicam = ref.watch(multicamProvider(projectId));
    final controller = ref.read(multicamProvider(projectId).notifier);
    final editor = ref.watch(editorControllerProvider(projectId));
    final theme = Theme.of(context);

    final hasClip = editor?.selectedClipId != null;

    return ToolSheet(
      title: 'Multicam',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add the other angles of the same take, line them up by sound, '
            'then tap an angle while watching to cut to it.',
            style: theme.textTheme.bodySmall,
          ),

          const SectionHeader(title: 'Angles'),
          if (multicam.angles.isEmpty)
            Text(
              'No angles yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final angle in multicam.angles)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  angle.synced
                      ? Icons.link_rounded
                      : Icons.link_off_rounded,
                  color: angle.synced
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  angle.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  angle == multicam.angles.first
                      ? 'Reference'
                      : angle.synced
                      ? 'offset ${angle.offset.inMilliseconds} ms · '
                            'match ${(angle.confidence * 100).round()}%'
                      : 'not matched — nudge it by hand',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (angle != multicam.angles.first) ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove_rounded, size: 18),
                        onPressed: () => controller.nudge(
                          angle.asset.id,
                          const Duration(milliseconds: -40),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        onPressed: () => controller.nudge(
                          angle.asset.id,
                          const Duration(milliseconds: 40),
                        ),
                      ),
                    ],
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => controller.removeAngle(angle.asset.id),
                    ),
                  ],
                ),
              ),

          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_addAngles(context, ref)),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add angle'),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton.icon(
                onPressed: multicam.isReady && !multicam.isSyncing
                    ? () => unawaited(controller.syncByAudio())
                    : null,
                icon: multicam.isSyncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.hearing_rounded),
                label: Text(multicam.isSyncing ? 'Listening…' : 'Sync by sound'),
              ),
            ],
          ),

          if (multicam.message != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(multicam.message!, style: theme.textTheme.bodySmall),
          ],

          const SectionHeader(title: 'Cut'),
          Text(
            hasClip
                ? 'Tapping an angle cuts the selected clip at the playhead '
                      'and shows that angle from there.'
                : 'Select the clip you are cutting first.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final (index, angle) in multicam.angles.indexed)
                FilledButton.tonal(
                  onPressed: hasClip
                      ? () {
                          controller.switchTo(angle.asset.id);
                          unawaited(HapticFeedback.mediumImpact());
                        }
                      : null,
                  child: Text('${index + 1} · ${angle.label}'),
                ),
            ],
          ),

          if (multicam.angles.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Consumer(
              builder: (context, ref, _) {
                final at = ref.watch(playheadControllerProvider).position;
                return Text(
                  'At ${TimeUtils.formatShort(at)} the angles are showing: '
                  '${multicam.angles.map((a) => TimeUtils.formatShort(a.sourceTimeAt(at))).join(', ')}',
                  style: theme.textTheme.bodySmall,
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _addAngles(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    final paths = picked?.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    if (paths == null || paths.isEmpty) return;

    final media = ref.read(mediaRepositoryProvider);
    final controller = ref.read(multicamProvider(projectId).notifier);
    for (final path in paths) {
      final imported = await media.importFile(path);
      final asset = imported.valueOrNull;
      if (asset != null) controller.addAngle(asset);
    }
  }
}
