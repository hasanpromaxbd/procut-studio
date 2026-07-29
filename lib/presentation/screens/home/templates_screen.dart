/// Template browser: pick a template, pick media, get a project.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/project_template.dart';
import '../../viewmodels/template_controller.dart';
import '../../widgets/common/glass_panel.dart';
import '../editor/editor_screen.dart';

class TemplatesScreen extends ConsumerWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templateListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      body: templates.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not load templates',
          message: '$error',
        ),
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.dashboard_customize_outlined,
                title: 'No templates yet',
                message:
                    'Open a project, then use Save as template. The cut '
                    'rhythm, effects and titles are kept; only the footage is '
                    'swapped out.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(Spacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: Spacing.md),
                itemBuilder: (context, index) => _TemplateCard(
                  template: list[index],
                  onApply: () => _apply(context, ref, list[index]),
                  onDelete: () => ref
                      .read(templateControllerProvider)
                      .delete(list[index].id),
                ),
              ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    ProjectTemplate template,
  ) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.media,
      allowMultiple: true,
    );
    final paths = picked?.files
        .map((PlatformFile f) => f.path)
        .whereType<String>()
        .toList();
    if (paths == null || paths.isEmpty || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final result = await ref
        .read(templateControllerProvider)
        .applyTemplate(template, paths);

    result.fold(
      (applied) {
        // Report shortfalls rather than letting the user discover a clip is
        // shorter than the template intended when they scrub past it.
        if (!applied.isComplete) {
          messenger.showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 6),
              content: Text(
                [
                  if (applied.unfilledSlots > 0)
                    '${applied.unfilledSlots} slot(s) had no media and were removed',
                  ...applied.shortfalls,
                ].join('\n'),
              ),
            ),
          );
        }
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => EditorScreen(projectId: applied.project.id),
          ),
        );
      },
      (failure) =>
          messenger.showSnackBar(SnackBar(content: Text(failure.message))),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.onApply,
    required this.onDelete,
  });

  final ProjectTemplate template;
  final VoidCallback onApply;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(template.name, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: onDelete,
                  tooltip: 'Delete',
                ),
              ],
            ),
            if (template.description.isNotEmpty)
              Text(
                template.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.sm,
              children: [
                Chip(
                  label: Text('${template.slotCount} clips needed'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  label: Text(TimeUtils.formatShort(template.duration)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            GradientButton(
              label: 'Use this template',
              icon: Icons.auto_awesome_motion_rounded,
              expand: true,
              onPressed: onApply,
            ),
          ],
        ),
      ),
    );
  }
}

/// Prompts for a name and saves the open project as a template.
Future<void> showSaveTemplateSheet(
  BuildContext context,
  WidgetRef ref,
  String projectId,
) async {
  final nameController = TextEditingController();
  final descriptionController = TextEditingController();

  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ToolSheet(
      title: 'Save as template',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Keeps the cut rhythm, transitions, effects and titles. Each media '
            'clip becomes a slot that new footage drops into, retimed to fit.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          TextField(
            controller: nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Template name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          TextField(
            controller: descriptionController,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What is it for? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Spacing.xl),
          GradientButton(
            label: 'Save template',
            icon: Icons.save_rounded,
            expand: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    ),
  );

  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final result = await ref
      .read(templateControllerProvider)
      .saveFromProject(
        projectId,
        name: nameController.text.trim().isEmpty
            ? 'Untitled template'
            : nameController.text.trim(),
        description: descriptionController.text.trim(),
      );

  result.fold(
    (template) => messenger.showSnackBar(
      SnackBar(
        content: Text('Saved "${template.name}" — ${template.slotCount} slots'),
      ),
    ),
    (failure) =>
        messenger.showSnackBar(SnackBar(content: Text(failure.message))),
  );
}
