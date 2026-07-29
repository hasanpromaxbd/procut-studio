/// The fixed gutter beside the timeline: per-track mute / hide / lock.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../domain/entities/track.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/timeline_view_controller.dart';

class TrackHeaderColumn extends ConsumerWidget {
  const TrackHeaderColumn({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final view = ref.watch(timelineViewControllerProvider);
    final theme = Theme.of(context);

    if (editor == null) return const SizedBox.shrink();

    final layouts = view.trackLayouts(editor.timeline);

    return SizedBox(
      height: view.totalHeight(editor.timeline),
      child: Stack(
        children: [
          // Spacer aligned with the ruler so headers line up with their rows.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: TimelineMetrics.rulerHeight,
            child: ColoredBox(color: theme.colorScheme.surfaceContainerLow),
          ),
          for (final layout in layouts)
            Positioned(
              top: layout.top,
              left: 0,
              right: 0,
              height: layout.height,
              child: _TrackHeader(
                projectId: projectId,
                track: layout.track,
                compact: layout.height < TimelineMetrics.audioTrackHeight,
              ),
            ),
        ],
      ),
    );
  }
}

class _TrackHeader extends ConsumerWidget {
  const _TrackHeader({
    required this.projectId,
    required this.track,
    required this.compact,
  });

  final String projectId;
  final Track track;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final accent = Color(track.type.colorValue);

    return Container(
      margin: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.xs)),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              track.displayName,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: track.hidden
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (!compact) ...[
            _HeaderIcon(
              icon: track.type == TrackType.audio
                  ? (track.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded)
                  : (track.hidden
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded),
              active: track.type == TrackType.audio ? !track.muted : !track.hidden,
              tooltip: track.type == TrackType.audio ? 'Mute' : 'Hide',
              onTap: () => track.type == TrackType.audio
                  ? controller.toggleTrackMute(track.id)
                  : controller.toggleTrackVisibility(track.id),
            ),
            _HeaderIcon(
              icon: track.locked ? Icons.lock_rounded : Icons.lock_open_rounded,
              active: !track.locked,
              tooltip: 'Lock',
              onTap: () => controller.toggleTrackLock(track.id),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Icon(
            icon,
            size: 14,
            color: active
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
