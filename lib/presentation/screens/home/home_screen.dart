/// Project library.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/timeline.dart';
import '../../viewmodels/bdrive_controller.dart';
import '../../viewmodels/home_controller.dart';
import '../../widgets/common/glass_panel.dart';
import '../editor/editor_screen.dart';
import '../settings/settings_screen.dart';
import 'templates_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final projects = ref.watch(projectListProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;

    // Tablets get more columns rather than wider cards — a 700px-wide project
    // thumbnail is not more useful than a 220px one.
    final columns = switch (width) {
      >= Breakpoints.expanded => 5,
      >= Breakpoints.medium => 4,
      >= Breakpoints.compact => 3,
      _ => 2,
    };

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _Header()),
            const SliverToBoxAdapter(child: _SearchField()),
            projects.when(
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load your projects',
                  message: '$error',
                ),
              ),
              data: (list) => list.isEmpty
                  ? SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.movie_creation_outlined,
                        title: 'No projects yet',
                        message:
                            'Start a new project and drop in your first clip.',
                        action: GradientButton(
                          label: strings.newProject,
                          icon: Icons.add_rounded,
                          onPressed: () => _createProject(context, ref),
                        ),
                      ),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        Spacing.lg,
                        Spacing.sm,
                        Spacing.lg,
                        120,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: Spacing.md,
                              mainAxisSpacing: Spacing.md,
                              childAspectRatio: 0.68,
                            ),
                        itemCount: list.length,
                        itemBuilder: (context, index) => _ProjectCard(
                          summary: list[index],
                          onTap: () => _openProject(context, list[index].id),
                          onMenu: () =>
                              _showProjectMenu(context, ref, list[index]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: projects.value?.isEmpty ?? true
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _createProject(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: Text(strings.newProject),
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.white,
            ),
    );
  }

  void _openProject(BuildContext context, String projectId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(projectId: projectId),
      ),
    );
  }

  Future<void> _createProject(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<_NewProjectRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _NewProjectSheet(),
    );
    if (result == null || !context.mounted) return;

    final id = await ref
        .read(homeControllerProvider.notifier)
        .createProject(
          name: result.name,
          aspect: result.aspect,
          fps: result.fps,
        );
    if (id != null && context.mounted) _openProject(context, id);
  }

  Future<void> _showProjectMenu(
    BuildContext context,
    WidgetRef ref,
    ProjectSummary summary,
  ) async {
    final controller = ref.read(homeControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final strings = ref.read(stringsProvider);

    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: Text(strings.rename),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_rounded),
              title: Text(strings.duplicateAction),
              onTap: () => Navigator.pop(context, 'duplicate'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Export project bundle'),
              subtitle: const Text('Project plus all its media, as one file'),
              onTap: () => Navigator.pop(context, 'bundle'),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Back up to Bdrive'),
              subtitle: const Text('Bundle and upload to your own server'),
              onTap: () => Navigator.pop(context, 'bdrive'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                strings.delete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'rename':
        final name = await _promptForName(context, initial: summary.name);
        if (name != null) await controller.renameProject(summary.id, name);

      case 'duplicate':
        await controller.duplicateProject(summary.id);

      case 'bundle':
        final result = await controller.exportBundle(summary.id);
        result.fold(
          (path) => messenger.showSnackBar(
            SnackBar(content: Text('Bundle saved to ${File(path).parent.path}')),
          ),
          (failure) => messenger.showSnackBar(
            SnackBar(content: Text(failure.message)),
          ),
        );

      case 'bdrive':
        messenger.showSnackBar(
          const SnackBar(content: Text('Backing up to Bdrive…')),
        );
        final error = await ref.read(bdriveBackupProvider)(summary.id);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                error ?? '"${summary.name}" backed up to Bdrive',
              ),
            ),
          );

      case 'delete':
        if (!context.mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${summary.name}"?'),
            content: Text(strings.deleteProjectWarning),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: Text(strings.delete),
              ),
            ],
          ),
        );
        if (confirmed ?? false) await controller.deleteProject(summary.id);
    }
  }

  Future<String?> _promptForName(
    BuildContext context, {
    required String initial,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Project name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sort = ref.watch(projectSortProvider);
    final strings = ref.watch(stringsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.lg,
        Spacing.lg,
        Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShaderMask(
                shaderCallback: (bounds) =>
                    AppColors.brandGradient.createShader(bounds),
                child: Text(
                  AppConstants.appName,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.dashboard_customize_outlined),
                tooltip: strings.templates,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TemplatesScreen(),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.file_open_outlined),
                tooltip: 'Import project bundle',
                onPressed: () => _importBundle(context, ref),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
          Text(
            AppConstants.appTagline,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in ProjectSort.values)
                  Padding(
                    padding: const EdgeInsets.only(right: Spacing.sm),
                    child: ChoiceChip(
                      label: Text(option.label),
                      selected: sort == option,
                      onSelected: (_) =>
                          ref.read(projectSortProvider.notifier).set(option),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importBundle(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final path = picked?.files.single.path;
    if (path == null || !context.mounted) return;

    if (!path.endsWith('.${AppConstants.projectBundleExtension}')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Pick a .pcstudio bundle exported from ProCut Studio.',
          ),
        ),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final result = await ref
        .read(homeControllerProvider.notifier)
        .importBundle(path);
    result.fold(
      (project) => messenger.showSnackBar(
        SnackBar(content: Text('Imported "${project.name}"')),
      ),
      (failure) =>
          messenger.showSnackBar(SnackBar(content: Text(failure.message))),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.summary,
    required this.onTap,
    required this.onMenu,
  });

  final ProjectSummary summary;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = summary.thumbnailPath;

    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      borderRadius: Radii.cardRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: Radii.cardRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb != null && File(thumb).existsSync())
                    Image.file(File(thumb), fit: BoxFit.cover)
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.brandViolet.withValues(alpha: 0.35),
                            AppColors.brandCyan.withValues(alpha: 0.22),
                          ],
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.movie_outlined,
                          size: 32,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton(
                      icon: const Icon(Icons.more_vert_rounded, size: 18),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        minimumSize: const Size(32, 32),
                      ),
                      onPressed: onMenu,
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: const BorderRadius.all(
                          Radius.circular(Radii.xs),
                        ),
                      ),
                      child: Text(
                        TimeUtils.formatShort(summary.duration),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            summary.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${summary.clipCount} clip${summary.clipCount == 1 ? '' : 's'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewProjectRequest {
  const _NewProjectRequest({
    required this.name,
    required this.aspect,
    required this.fps,
  });

  final String name;
  final AspectPreset aspect;
  final int fps;
}

class _NewProjectSheet extends StatefulWidget {
  const _NewProjectSheet();

  @override
  State<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<_NewProjectSheet> {
  final TextEditingController _name = TextEditingController(
    text: 'Untitled project',
  );
  AspectPreset _aspect = AspectPreset.vertical9x16;
  int _fps = 30;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ToolSheet(
      title: 'New project',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Project name',
              border: OutlineInputBorder(),
            ),
          ),
          const SectionHeader(title: 'Canvas'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final preset in AspectPreset.values)
                if (preset != AspectPreset.custom)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: _aspect == preset,
                    onSelected: (_) => setState(() => _aspect = preset),
                  ),
            ],
          ),
          const SectionHeader(title: 'Frame rate'),
          Wrap(
            spacing: Spacing.sm,
            children: [
              for (final fps in [24, 25, 30, 50, 60])
                ChoiceChip(
                  label: Text('$fps fps'),
                  selected: _fps == fps,
                  onSelected: (_) => setState(() => _fps = fps),
                ),
            ],
          ),
          const SizedBox(height: Spacing.xl),
          GradientButton(
            label: 'Create',
            icon: Icons.auto_awesome_rounded,
            expand: true,
            onPressed: () => Navigator.pop(
              context,
              _NewProjectRequest(
                name: _name.text,
                aspect: _aspect,
                fps: _fps,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Finds a project by name once there are too many to scan.
class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(projectQueryProvider);
    if (_controller.text != query) {
      _controller.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.sm,
      ),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search projects',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () =>
                      ref.read(projectQueryProvider.notifier).clear(),
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (value) =>
            ref.read(projectQueryProvider.notifier).set(value),
      ),
    );
  }
}
