/// The editor: preview, transport, timeline, tool rail.
///
/// Layout adapts at [Breakpoints.compact]: phones stack preview over timeline,
/// tablets put the tool rail beside the preview so the timeline keeps its full
/// width — which is the dimension that actually matters when editing.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/di/providers.dart';
import '../../../core/error/failure.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/timeline.dart';
import '../../../domain/entities/track.dart';
import '../../../engine/timeline/playback_clock.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/editor_state.dart';
import '../../viewmodels/eyedropper_controller.dart';
import '../../viewmodels/playhead_controller.dart';
import '../../viewmodels/timeline_view_controller.dart';
import '../../widgets/common/glass_panel.dart';
import '../../widgets/editor/guides_overlay.dart';
import '../../widgets/editor/preview_stage.dart';
import '../../widgets/timeline/timeline_widget.dart';
import '../export/export_screen.dart';
import '../home/templates_screen.dart';
import 'editor_shortcuts.dart';
import 'sheets/ai_tools_sheet.dart';
import 'sheets/audio_detail_sheet.dart';
import 'sheets/caption_sheet.dart';
import 'sheets/chapters_sheet.dart';
import 'sheets/curve_sheet.dart';
import 'sheets/effects_sheet.dart';
import 'sheets/history_sheet.dart';
import 'sheets/jump_cut_sheet.dart';
import 'sheets/layout_sheet.dart';
import 'sheets/mask_sheet.dart';
import 'sheets/media_sheet.dart';
import 'sheets/mixer_sheet.dart';
import 'sheets/motion_sheet.dart';
import 'sheets/multicam_sheet.dart';
import 'sheets/record_sheet.dart';
import 'sheets/rhythm_sheet.dart';
import 'sheets/scopes_sheet.dart';
import 'sheets/speed_sheet.dart';
import 'sheets/text_sheet.dart';
import 'sheets/transition_sheet.dart';
import 'sheets/trim_sheet.dart';

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
        ref.read(editorControllerProvider(widget.projectId).notifier).flush(),
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

    ref.listen<EditorState?>(editorControllerProvider(widget.projectId), (
      previous,
      next,
    ) {
      final message = next?.errorMessage;
      if (message != null && message != previous?.errorMessage) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
        ref
            .read(editorControllerProvider(widget.projectId).notifier)
            .clearMessages();
      }
    });

    if (editor == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isTablet = Breakpoints.isTablet(MediaQuery.sizeOf(context).width);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final controller = ref.read(
          editorControllerProvider(widget.projectId).notifier,
        );
        // Back out of a group first: leaving with it still open would discard
        // the whole inner session.
        if (ref.read(editorControllerProvider(widget.projectId))
                ?.isInsideGroup ??
            false) {
          controller.exitGroup();
          return;
        }
        await controller.flush();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: EditorShortcutsScope(
        projectId: widget.projectId,
        child: Scaffold(
          appBar: _buildAppBar(editor),
          body: Column(
            children: [
              if (editor.isInsideGroup)
                _GroupBreadcrumb(projectId: widget.projectId),
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
    final strings = ref.watch(stringsProvider);
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
              ? strings.undo
              : '${strings.undo} ${editor.undoLabel}',
          onPressed: editor.canUndo ? controller.undo : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo_rounded),
          tooltip: editor.redoLabel == null
              ? strings.redo
              : '${strings.redo} ${editor.redoLabel}',
          onPressed: editor.canRedo ? controller.redo : null,
        ),
        IconButton(
          icon: const Icon(Icons.history_rounded),
          tooltip: strings.history,
          onPressed: (editor.canUndo || editor.canRedo)
              ? () => unawaited(
                  ToolSheet.show<void>(
                    context,
                    sheet: HistorySheet(projectId: widget.projectId),
                  ),
                )
              : null,
        ),
        Consumer(
          builder: (context, ref, _) {
            final guides = ref.watch(guidesProvider);
            return MenuAnchor(
              builder: (context, menu, _) => IconButton(
                icon: Icon(
                  guides.anyOn ? Icons.grid_on_rounded : Icons.grid_off_rounded,
                ),
                tooltip: strings.compositionGuides,
                isSelected: guides.anyOn,
                onPressed: () => menu.isOpen ? menu.close() : menu.open(),
              ),
              menuChildren: [
                for (final kind in GuideKind.values)
                  CheckboxMenuButton(
                    value: guides.isOn(kind),
                    onChanged: (_) =>
                        ref.read(guidesProvider.notifier).toggle(kind),
                    child: Text(kind.label),
                  ),
              ],
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.photo_camera_rounded),
          tooltip: 'Save this frame as an image',
          onPressed: () => unawaited(_snapshotFrame()),
        ),
        IconButton(
          icon: const Icon(Icons.area_chart_rounded),
          tooltip: strings.scopes,
          onPressed: () => unawaited(
            ToolSheet.show<void>(
              context,
              sheet: ScopesSheet(projectId: widget.projectId),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.aspect_ratio_rounded),
          tooltip: strings.reframe,
          onPressed: _reframe,
        ),
        IconButton(
          icon: const Icon(Icons.dashboard_customize_outlined),
          tooltip: strings.saveAsTemplate,
          onPressed: () =>
              showSaveTemplateSheet(context, ref, widget.projectId),
        ),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm, left: Spacing.xs),
          child: FilledButton.icon(
            onPressed: editor.timeline.isEmpty
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ExportScreen(projectId: widget.projectId),
                    ),
                  ),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(strings.export),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            ),
          ),
        ),
      ],
    );
  }

  /// Converts the project to another aspect ratio, recentring every clip.
  ///
  /// Without tracking data this centres rather than follows a subject — still
  /// better than the letterboxing a bare canvas change would produce, and the
  /// sheet says so rather than implying it is smart.
  Future<void> _reframe() async {
    final preset = await showModalBottomSheet<AspectPreset>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Text(
                'Reframe the whole project. Every clip is recentred for the new '
                'shape; run face tracking first if you want it to follow a '
                'subject.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final option in AspectPreset.values)
              if (option != AspectPreset.custom)
                ListTile(
                  leading: const Icon(Icons.crop_rounded),
                  title: Text(option.label),
                  subtitle: Text('${option.width} × ${option.height}'),
                  onTap: () => Navigator.pop(context, option),
                ),
          ],
        ),
      ),
    );
    if (preset == null || !mounted) return;
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .autoReframe(preset);
  }

  /// The frame exactly as previewed — effects, titles, masks — shared as a
  /// PNG through the system sheet.
  Future<void> _snapshotFrame() async {
    final messenger = ScaffoldMessenger.of(context);
    final png = await ref
        .read(eyedropperProvider.notifier)
        .snapshotPng();
    if (png == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not capture the preview.')),
      );
      return;
    }
    final paths = ref.read(pathServiceProvider);
    final file = File(
      p.join(
        paths.tempDir.path,
        'frame-${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(png);
    final result = await ref
        .read(exportRepositoryProvider)
        .share(file.path, subject: 'Frame from ProCut Studio');
    result.fold(
      (_) {},
      (failure) =>
          messenger.showSnackBar(SnackBar(content: Text(failure.message))),
    );
  }

  Future<void> _renameProject(String current) async {
    final strings = ref.read(stringsProvider);
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.projectName),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(strings.save),
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

      case _ToolAction.record:
        await _recordVoiceOver();

      case _ToolAction.ai:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: AiToolsSheet(projectId: widget.projectId),
        );

      case _ToolAction.mask:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: MaskSheet(projectId: widget.projectId),
        );

      case _ToolAction.marker:
        controller.addMarkerAtPlayhead();
        await HapticFeedback.selectionClick();

      case _ToolAction.copy:
        controller.copySelection();

      case _ToolAction.paste:
        controller.paste();

      case _ToolAction.rotate:
        controller.rotateSelected();

      case _ToolAction.flip:
        controller.flipSelected(horizontal: true);

      case _ToolAction.freeze:
        controller.freezeFrameAtPlayhead();

      case _ToolAction.reverse:
        controller.reverseSelected();

      case _ToolAction.trim:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: TrimSheet(projectId: widget.projectId),
        );

      case _ToolAction.motion:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: MotionSheet(projectId: widget.projectId),
        );

      case _ToolAction.rhythm:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: RhythmSheet(projectId: widget.projectId),
        );

      case _ToolAction.multicam:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: MulticamSheet(projectId: widget.projectId),
        );

      case _ToolAction.audioDetail:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: AudioDetailSheet(projectId: widget.projectId),
        );

      case _ToolAction.chapters:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: ChaptersSheet(projectId: widget.projectId),
        );

      case _ToolAction.curves:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: CurveSheet(projectId: widget.projectId),
        );

      case _ToolAction.media:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: MediaSheet(projectId: widget.projectId),
        );

      case _ToolAction.captions:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: CaptionSheet(projectId: widget.projectId),
        );

      case _ToolAction.layout:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: LayoutSheet(projectId: widget.projectId),
        );

      case _ToolAction.group:
        controller.toggleGroup();
        await HapticFeedback.selectionClick();

      case _ToolAction.jumpCut:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: JumpCutSheet(projectId: widget.projectId),
        );

      case _ToolAction.mixer:
        if (!mounted) return;
        await ToolSheet.show<void>(
          context,
          sheet: MixerSheet(projectId: widget.projectId),
        );

      case _ToolAction.addTrack:
        if (!mounted) return;
        final type = await showModalBottomSheet<TrackType>(
          context: context,
          useSafeArea: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in [
                  TrackType.overlay,
                  TrackType.video,
                  TrackType.audio,
                  TrackType.text,
                  TrackType.adjustment,
                ])
                  ListTile(
                    leading: Icon(switch (option) {
                      TrackType.adjustment => Icons.tune_rounded,
                      TrackType.audio => Icons.graphic_eq_rounded,
                      TrackType.text => Icons.title_rounded,
                      _ => Icons.layers_rounded,
                    }, color: Color(option.colorValue)),
                    title: Text('${option.label} track'),
                    subtitle: option == TrackType.adjustment
                        ? const Text(
                            'Effects here apply to every layer below it',
                          )
                        : null,
                    onTap: () => Navigator.pop(context, option),
                  ),
              ],
            ),
          ),
        );
        if (type != null) controller.addTrack(type);
    }
  }

  /// Mic permission is requested before the sheet opens, so the user is not
  /// shown a recorder they cannot actually start.
  Future<void> _recordVoiceOver() async {
    final permissions = ref.read(permissionServiceProvider);
    final granted = await permissions.request(MediaPermissionKind.microphone);

    if (!mounted) return;
    if (granted.isErr) {
      final failure = granted.failureOrNull!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failure.message),
          action: failure is PermissionFailure && failure.permanentlyDenied
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: () => unawaited(permissions.openSettings()),
                )
              : null,
        ),
      );
      return;
    }

    // Recording while the timeline plays would capture the playback itself.
    ref.read(playheadControllerProvider.notifier).pause();

    await ToolSheet.show<void>(
      context,
      sheet: RecordSheet(projectId: widget.projectId),
    );
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
                        text:
                            '  /  ${TimeUtils.formatShort(playhead.duration)}',
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
  record,
  ai,
  mask,
  marker,
  copy,
  paste,
  rotate,
  flip,
  freeze,
  reverse,
  trim,
  motion,
  rhythm,
  jumpCut,
  group,
  layout,
  captions,
  media,
  curves,
  chapters,
  audioDetail,
  multicam,
  mixer,
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
    final strings = ref.watch(stringsProvider);

    final buttons = <Widget>[
      ToolIconButton(
        icon: Icons.add_photo_alternate_outlined,
        label: strings.toolMedia,
        onPressed: () => onAction(_ToolAction.addMedia),
      ),
      ToolIconButton(
        icon: Icons.content_cut_rounded,
        label: strings.toolSplit,
        onPressed: () => onAction(_ToolAction.split),
      ),
      ToolIconButton(
        icon: Icons.speed_rounded,
        label: strings.toolSpeed,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.speed),
      ),
      ToolIconButton(
        icon: Icons.auto_fix_high_rounded,
        label: strings.toolEffects,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.effects),
      ),
      ToolIconButton(
        icon: Icons.compare_arrows_rounded,
        label: strings.toolTransition,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.transition),
      ),
      ToolIconButton(
        icon: Icons.title_rounded,
        label: strings.toolText,
        onPressed: () => onAction(_ToolAction.text),
      ),
      ToolIconButton(
        icon: Icons.mic_rounded,
        label: strings.toolRecord,
        onPressed: () => onAction(_ToolAction.record),
      ),
      ToolIconButton(
        icon: Icons.auto_awesome_rounded,
        label: strings.toolAi,
        onPressed: () => onAction(_ToolAction.ai),
      ),
      ToolIconButton(
        icon: Icons.crop_free_rounded,
        label: strings.toolMask,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.mask),
      ),
      ToolIconButton(
        icon: Icons.flag_rounded,
        label: strings.toolMarker,
        onPressed: () => onAction(_ToolAction.marker),
      ),
      ToolIconButton(
        icon: Icons.copy_all_rounded,
        label: strings.toolCopy,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.copy),
      ),
      ToolIconButton(
        icon: Icons.content_paste_rounded,
        label: strings.toolPaste,
        enabled: editor?.canPaste ?? false,
        onPressed: () => onAction(_ToolAction.paste),
      ),
      ToolIconButton(
        icon: Icons.rotate_90_degrees_cw_rounded,
        label: strings.toolRotate,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.rotate),
      ),
      ToolIconButton(
        icon: Icons.flip_rounded,
        label: strings.toolFlip,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.flip),
      ),
      ToolIconButton(
        icon: Icons.ac_unit_rounded,
        label: strings.toolFreeze,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.freeze),
      ),
      ToolIconButton(
        icon: Icons.fast_rewind_rounded,
        label: strings.toolReverse,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.reverse),
      ),
      ToolIconButton(
        icon: Icons.swap_horiz_rounded,
        label: strings.toolTrim,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.trim),
      ),
      ToolIconButton(
        icon: Icons.videocam_rounded,
        label: strings.toolMotion,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.motion),
      ),
      ToolIconButton(
        icon: Icons.graphic_eq_rounded,
        label: strings.toolBeats,
        onPressed: () => onAction(_ToolAction.rhythm),
      ),
      ToolIconButton(
        icon: Icons.tune_rounded,
        label: strings.toolMixer,
        onPressed: () => onAction(_ToolAction.mixer),
      ),
      ToolIconButton(
        icon: Icons.cut_rounded,
        label: strings.toolJumpCut,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.jumpCut),
      ),
      ToolIconButton(
        icon: Icons.switch_video_rounded,
        label: strings.toolMulticam,
        onPressed: () => onAction(_ToolAction.multicam),
      ),
      ToolIconButton(
        icon: Icons.graphic_eq_rounded,
        label: strings.toolAudioDetail,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.audioDetail),
      ),
      ToolIconButton(
        icon: Icons.bookmarks_rounded,
        label: strings.toolChapters,
        onPressed: () => onAction(_ToolAction.chapters),
      ),
      ToolIconButton(
        icon: Icons.show_chart_rounded,
        label: strings.toolCurves,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.curves),
      ),
      ToolIconButton(
        icon: Icons.perm_media_rounded,
        label: strings.toolMedia2,
        onPressed: () => onAction(_ToolAction.media),
      ),
      ToolIconButton(
        icon: Icons.closed_caption_rounded,
        label: strings.toolCaptions,
        onPressed: () => onAction(_ToolAction.captions),
      ),
      ToolIconButton(
        icon: Icons.dashboard_rounded,
        label: strings.toolLayout,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.layout),
      ),
      ToolIconButton(
        icon: Icons.join_full_rounded,
        label: strings.toolGroup,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.group),
      ),
      ToolIconButton(
        icon: Icons.copy_rounded,
        label: strings.toolDuplicate,
        enabled: hasSelection,
        onPressed: () => onAction(_ToolAction.duplicate),
      ),
      ToolIconButton(
        icon: Icons.layers_rounded,
        label: strings.toolTrack,
        onPressed: () => onAction(_ToolAction.addTrack),
      ),
      ToolIconButton(
        icon: Icons.delete_outline_rounded,
        label: strings.toolDelete,
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


/// Shown while the editor is inside a group: where you are and the way out.
///
/// A modal state with no visible indicator is how people lose work, so this
/// is a bar rather than a subtle badge.
class _GroupBreadcrumb extends ConsumerWidget {
  const _GroupBreadcrumb({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final context0 = editor?.compoundEdit;
    if (context0 == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            children: [
              Icon(
                Icons.subdirectory_arrow_right_rounded,
                size: 18,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'Inside "${context0.label}" — edits apply to the group',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => ref
                    .read(editorControllerProvider(projectId).notifier)
                    .exitGroup(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
