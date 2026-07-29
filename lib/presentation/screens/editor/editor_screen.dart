/// The editor: preview, transport, timeline, tool rail.
///
/// Layout adapts at [Breakpoints.compact]: phones stack preview over timeline,
/// tablets put the tool rail beside the preview so the timeline keeps its full
/// width — which is the dimension that actually matters when editing.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/track.dart';
import '../../../engine/timeline/playback_clock.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/editor_state.dart';
import '../../viewmodels/playhead_controller.dart';
import '../../viewmodels/timeline_view_controller.dart';
import '../../widgets/common/glass_panel.dart';
import '../../widgets/editor/preview_stage.dart';
import '../../widgets/timeline/timeline_widget.dart';
import '../export/export_screen.dart';
import 'sheets/effects_sheet.dart';
import 'sheets/speed_sheet.dart';
import 'sheets/text_sheet.dart';
import 'sheets/transition_sheet.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  PlaybackClock? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = PlaybackClock(vsync: this)
      ..onTick = (position) {
        ref.read(playheadControllerProvider.notifier).tick(position);
        // Keep the playhead on screen without fighting a manual scroll.
        ref
            .read(timelineViewControllerProvider.notifier)
            .followPlayhead(position);
      }
      ..onCompleted = () =>
          ref.read(playheadControllerProvider.notifier).pause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android can kill the process from the background without warning, so
    // flush before we lose the chance.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref
            .read(editorControllerProvider(widget.projectId).notifier)
            .flush(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final playhead = ref.watch(playheadControllerProvider);

    // Mirror transport state onto the clock. Done in build rather than a
    // listener so it cannot get out of sync after a hot reload.
    _syncClock(playhead, editor);

    ref.listen<EditorState?>(
      editorControllerProvider(widget.projectId),
      (previous, next) {
        final message = next?.errorMessage;
        if (message != null && message != previous?.errorMessage) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(message)));
          ref
              .read(editorControllerProvider(widget.projectId).notifier)
              .clearMessages();
        }
      },
    );

    if (editor == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isTablet = Breakpoints.isTablet(MediaQuery.sizeOf(context).width);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await ref
            .read(editorControllerProvider(widget.projectId).notifier)
            .flush();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: _buildAppBar(editor),
        body: Column(
          children: [
            Expanded(
              flex: isTablet ? 6 : 5,
              child: isTablet
                  ? Row(
                      children: [
                        Expanded(
                          child: PreviewStage(projectId: widget.projectId),
                        ),
                        SizedBox(
                          width: 76,
                          child: _ToolRail(
                            projectId: widget.projectId,
                            vertical: true,
                            onAction: _handleToolAction,
                          ),
                        ),
                      ],
                    )
                  : PreviewStage(projectId: widget.projectId),
            ),
            _TransportBar(projectId: widget.projectId),
            Expanded(
              flex: isTablet ? 5 : 4,
              child: TimelineWidget(projectId: widget.projectId),
            ),
            if (!isTablet)
              _ToolRail(
                projectId: widget.projectId,
                vertical: false,
                onAction: _handleToolAction,
              ),
          ],
        ),
      ),
    );
  }

  void _syncClock(PlayheadState playhead, EditorState? editor) {
    final clock = _clock;
    if (clock == null) return;

    clock.duration = playhead.duration;
    clock.looping = playhead.looping;
    if (clock.rate != playhead.rate) clock.rate = playhead.rate;

    if (playhead.isPlaying && !clock.isPlaying) {
      clock.seek(playhead.position);
      clock.play();
    } else if (!playhead.isPlaying && clock.isPlaying) {
      clock.pause();
    } else if (!playhead.isPlaying &&
        (clock.position - playhead.position).abs() >
            const Duration(milliseconds: 8)) {
      // The user scrubbed; move the clock so playback resumes from there.
      clock.seek(playhead.position, fps: editor?.timeline.fps);
    }
  }

  PreferredSizeWidget _buildAppBar(EditorState editor) {
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: GestureDetector(
        onTap: () => _renameProject(editor.project.name),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                editor.project.name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (editor.isDirty)
              Padding(
                padding: const EdgeInsets.only(left: Spacing.sm),
                child: Icon(
                  Icons.circle,
                  size: 7,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.undo_rounded),
          tooltip: editor.undoLabel == null
              ? 'Undo'
              : 'Undo ${editor.undoLabel}',
          onPressed: editor.canUndo ? controller.undo : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo_rounded),
          tooltip: editor.redoLabel == null
              ? 'Redo'
              : 'Redo ${editor.redoLabel}',
          onPressed: editor.canRedo ? controller.redo : null,
        ),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm, left: Spacing.xs),
          child: FilledButton.icon(
            onPressed: editor.timeline.isEmpty
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ExportScreen(projectId: widget.projectId),
                    ),
                  ),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('Export'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _renameProject(String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Project name'),
        content: TextField(controller: controller, autofocus: true),
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
    if (name != null && name.trim().isNotEmpty) {
      ref
          .read(editorControllerProvider(widget.projectId).notifier)
          .rename(name.trim());
    }
  }

  Future<void> _handleToolAction(_ToolAction action) async {
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );

    switch (action) {
      case _ToolAction.addMedia:
        await _importMedia();

      case _ToolAction.split:
        controller.splitAtPlayhead();
        await HapticFeedback.selectionClick();

      case _ToolAction.delete:
        controller.deleteSelected(
          ripple: ref.read(timelineViewControllerProvider).rippleEnabled,
        );

      case _ToolAction.duplicate:
        controller.duplicateSelected();

      case _ToolAction.speed:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: SpeedSheet(projectId: widget.projectId),
        );

      case _ToolAction.effects:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: EffectsSheet(projectId: widget.projectId),
        );

      case _ToolAction.transition:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: TransitionSheet(projectId: widget.projectId),
        );

      case _ToolAction.text:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: TextSheet(projectId: widget.projectId),
        );

      case _ToolAction.rotate:
        controller.rotateSelected();

      case _ToolAction.flip:
        controller.flipSelected(horizontal: true);

      case _ToolAction.freeze:
        controller.freezeFrameAtPlayhead();

      case _ToolAction.reverse:
        controller.reverseSelected();

      case _ToolAction.addTrack:
        controller.addTrack(TrackType.overlay);
    }
  }

  Future<void> _importMedia() async {
    final permissions = ref.read(permissionServiceProvider);
    final granted = await permissions.request(MediaPermissionKind.video);

    if (granted.isErr) {
      if (!mounted) return;
      final failure = granted.failureOrNull!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failure.message),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => unawaited(permissions.openSettings()),
          ),
        ),
      );
      return;
    }

    final picked = await FilePicker.pickFiles(
      type: FileType.media,
      allowMultiple: true,
    );
    final paths = picked?.files
        .map((PlatformFile f) => f.path)
        .whereType<String>()
        .toList();
    if (paths == null || paths.isEmpty) return;

    await ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .addMedia(paths);
  }
}

// ── Transport ──────────────────────────────────────────────────────────

class _TransportBar extends ConsumerWidget {
  const _TransportBar({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playhead = ref.watch(playheadControllerProvider);
    final editor = ref.watch(editorControllerProvider(projectId));
    final view = ref.watch(timelineViewControllerProvider);
    final controller = ref.read(playheadControllerProvider.notifier);
    final fps = editor?.timeline.fps ?? 30;
    controller.fps = fps;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous_rounded),
              tooltip: 'Previous edit',
              onPressed: () => controller.jumpToEditPoint(
                editor?.timeline.editPoints ?? const [],
                forward: false,
              ),
            ),
            IconButton(
              icon: Icon(
                playhead.isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                size: 34,
              ),
              color: Theme.of(context).colorScheme.primary,
              tooltip: playhead.isPlaying ? 'Pause' : 'Play',
              onPressed: controller.togglePlay,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next_rounded),
              tooltip: 'Next edit',
              onPressed: () => controller.jumpToEditPoint(
                editor?.timeline.editPoints ?? const [],
                forward: true,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: TimeUtils.formatSmpte(playhead.position, fps),
                      ),
                      TextSpan(
                        text: '  /  ${TimeUtils.formatShort(playhead.duration)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  style: AppTheme.timecode(context),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                view.snapEnabled
                    ? Icons.grid_on_rounded
                    : Icons.grid_off_rounded,
              ),
              tooltip: view.snapEnabled ? 'Snapping on' : 'Snapping off',
              color: view.snapEnabled
                  ? Theme.of(context).colorScheme.secondary
                  : null,
              onPressed: ref
                  .read(timelineViewControllerProvider.notifier)
                  .toggleSnap,
            ),
            IconButton(
              icon: const Icon(Icons.zoom_out_map_rounded),
              tooltip: 'Fit timeline',
              onPressed: () => ref
                  .read(timelineViewControllerProvider.notifier)
                  .zoomToFit(playhead.duration),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tool rail ──────────────────────────────────────────────────────────

enum _ToolAction {
  addMedia,
  split,
  delete,
  duplicate,
  speed,
  effects,
  transition,
  text,
  rotate,
  flip,
  freeze,
  reverse,
  addTrack,
}

class _ToolRail extends ConsumerWidget {
  const _ToolRail({
    required this.projectId,
    required this.vertical,
    required this.onAction,
  });

  final String projectId;
  final bool vertical;
  final Future<void> Function(_ToolAction action) onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final hasSelection = editor?.hasSelection ?? false;

    final buttons = <Widget>[
      ToolIconButton(
        icon: Icons.add_photo_alternate_outlined,
        label: 'Media',
        onPressed: () => onAction(_ToolAction.addMedia),
      ),
      ToolIconButton(
        icon: Icons.content_cut_rounded,
        label: 'Split',
        onPressed: () => onAction(_ToolAction.split),
      ),
      ToolIconButton(
        icon: Icons.speed_rounded,
        label: 'Speed',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.speed),
      ),
      ToolIconButton(
        icon: Icons.auto_fix_high_rounded,
        label: 'Effects',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.effects),
      ),
      ToolIconButton(
        icon: Icons.compare_arrows_rounded,
        label: 'Transition',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.transition),
      ),
      ToolIconButton(
        icon: Icons.title_rounded,
        label: 'Text',
        onPressed: () => onAction(_ToolAction.text),
      ),
      ToolIconButton(
        icon: Icons.rotate_90_degrees_cw_rounded,
        label: 'Rotate',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.rotate),
      ),
      ToolIconButton(
        icon: Icons.flip_rounded,
        label: 'Flip',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.flip),
      ),
      ToolIconButton(
        icon: Icons.ac_unit_rounded,
        label: 'Freeze',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.freeze),
      ),
      ToolIconButton(
        icon: Icons.fast_rewind_rounded,
        label: 'Reverse',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.reverse),
      ),
      ToolIconButton(
        icon: Icons.copy_rounded,
        label: 'Duplicate',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.duplicate),
      ),
      ToolIconButton(
        icon: Icons.layers_rounded,
        label: 'Track',
        onPressed: () => onAction(_ToolAction.addTrack),
      ),
      ToolIconButton(
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.delete),
      ),
    ];

    if (vertical) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Column(children: buttons),
      );
    }

    return SafeArea(
      top: false,
      child: SizedBox(
        height: 74,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          children: buttons,
        ),
      ),
    );
  }
}
