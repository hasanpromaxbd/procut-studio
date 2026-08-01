/// Export settings and progress.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/export_job.dart';
import '../../../domain/entities/export_preset.dart';
import '../../../domain/entities/export_range.dart';
import '../../../domain/entities/export_settings.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/export_controller.dart';
import '../../viewmodels/export_queue_controller.dart';
import '../../viewmodels/playhead_controller.dart';
import '../../widgets/common/glass_panel.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final editor = ref.read(editorControllerProvider(widget.projectId));
      if (editor != null) {
        ref.read(exportSettingsProvider.notifier).seedFrom(editor.project);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final settings = ref.watch(exportSettingsProvider);
    final progress = ref.watch(exportControllerProvider);
    final strings = ref.watch(stringsProvider);

    if (editor == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.export),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: progress == null
          ? _SettingsForm(projectId: widget.projectId)
          : _ProgressView(projectId: widget.projectId, progress: progress),
      bottomNavigationBar: progress != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RangeRow(projectId: widget.projectId),
                    const _QueueSummary(),
                    Row(
                      children: [
                        Expanded(
                          child: GradientButton(
                            label: strings.startExport,
                            icon: Icons.movie_filter_rounded,
                            expand: true,
                            onPressed: settings.validate().isEmpty
                                ? () async {
                                    // Asked for, but never required: without
                                    // it the export still runs, it just cannot
                                    // show progress in the shade. Blocking the
                                    // render over a notification would be
                                    // absurd.
                                    await ref
                                        .read(permissionServiceProvider)
                                        .request(
                                          MediaPermissionKind.notifications,
                                        );
                                    await ref
                                        .read(exportControllerProvider.notifier)
                                        .start(
                                          editor.project,
                                          settings,
                                          range: ref.read(exportRangeProvider),
                                        );
                                  }
                                : null,
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        // Queue instead of start: line up several settings and
                        // let them run back to back.
                        IconButton.filledTonal(
                          tooltip: strings.addToQueue,
                          icon: const Icon(Icons.playlist_add_rounded),
                          onPressed: settings.validate().isEmpty
                              ? () {
                                  ref
                                      .read(exportQueueProvider.notifier)
                                      .enqueue(editor.project, settings);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Queued — change the settings and '
                                        'queue another, or leave it to run.',
                                      ),
                                    ),
                                  );
                                }
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SettingsForm extends ConsumerWidget {
  const _SettingsForm({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(exportSettingsProvider);
    final controller = ref.read(exportSettingsProvider.notifier);
    final editor = ref.watch(editorControllerProvider(projectId));
    final theme = Theme.of(context);

    final timeline = editor!.timeline;
    final (width, height) = settings.dimensionsFor(timeline.width, timeline.height);
    final estimate = settings.estimatedBytes(
      timeline.duration,
      timeline.width,
      timeline.height,
    );
    final issues = settings.validate();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.xxl,
      ),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Output', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                _Row(label: 'Resolution', value: '$width × $height'),
                _Row(
                  label: 'Duration',
                  value: TimeUtils.formatShort(timeline.duration),
                ),
                _Row(
                  label: 'Estimated size',
                  value: TimeUtils.formatBytes(estimate),
                ),
                _Row(
                  label: 'Bitrate',
                  value:
                      '${settings.effectiveVideoBitrateKbps(timeline.width, timeline.height)} kbps',
                ),
              ],
            ),
          ),
        ),

        const SectionHeader(title: 'Target'),
        Text(
          'A preset sets everything below. Platforms re-encode whatever you '
          'send, so a clean master at the right shape beats a huge upload.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final preset in ExportPreset.all)
              ActionChip(
                avatar: preset.matches(timeline)
                    ? Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: theme.colorScheme.secondary,
                      )
                    : null,
                label: Text(preset.name),
                tooltip: preset.description,
                onPressed: () => controller.applyPreset(preset),
              ),
          ],
        ),
        Builder(
          builder: (context) {
            // Warn about the two things a preset cannot silently fix.
            final over = ExportPreset.all
                .where((p) => p.exceedsLimit(timeline.duration))
                .map((p) => p.name)
                .toList();
            if (over.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(
                'This edit is ${TimeUtils.formatShort(timeline.duration)} — '
                'too long for ${over.join(', ')}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            );
          },
        ),

        const SectionHeader(title: 'Resolution'),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final option in ExportResolution.values)
              ChoiceChip(
                label: Text(option.label),
                selected: settings.resolution == option,
                onSelected: (_) => controller.setResolution(option),
              ),
          ],
        ),

        const SectionHeader(title: 'Frame rate'),
        Wrap(
          spacing: Spacing.sm,
          children: [
            for (final fps in [24, 25, 30, 50, 60])
              ChoiceChip(
                label: Text('$fps'),
                selected: settings.fps == fps,
                onSelected: (_) => controller.setFps(fps),
              ),
          ],
        ),

        const SectionHeader(title: 'Codec'),
        Wrap(
          spacing: Spacing.sm,
          children: [
            for (final codec in VideoCodec.values)
              ChoiceChip(
                label: Text(codec.label),
                selected: settings.videoCodec == codec,
                onSelected: (_) => controller.setCodec(codec),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xs),
          child: Text(
            settings.videoCodec == VideoCodec.hevc
                ? 'HEVC gives the same quality at roughly 60% of the size, but '
                      'some older players and web uploads reject it.'
                : 'H.264 plays everywhere. Pick it unless you need the smaller '
                      'file.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),

        const SectionHeader(title: 'Container'),
        Wrap(
          spacing: Spacing.sm,
          children: [
            for (final container in ExportContainer.values)
              ChoiceChip(
                label: Text(container.label),
                selected: settings.container == container,
                onSelected: (_) => controller.setContainer(container),
              ),
          ],
        ),

        const SectionHeader(title: 'Quality'),
        SegmentedButton<BitrateMode>(
          segments: [
            for (final mode in BitrateMode.values)
              ButtonSegment(value: mode, label: Text(mode.label)),
          ],
          selected: {settings.bitrateMode},
          onSelectionChanged: (selection) =>
              controller.setBitrateMode(selection.first),
        ),
        const SizedBox(height: Spacing.md),
        if (settings.bitrateMode == BitrateMode.quality)
          Wrap(
            spacing: Spacing.sm,
            children: [
              for (final preset in QualityPreset.values)
                ChoiceChip(
                  label: Text(preset.label),
                  selected: settings.quality == preset,
                  onSelected: (_) => controller.setQuality(preset),
                ),
            ],
          )
        else
          LabeledSlider(
            label: 'Video bitrate',
            value: settings.customVideoBitrateKbps.toDouble(),
            min: 500,
            max: 60000,
            formatter: (v) => '${(v / 1000).toStringAsFixed(1)} Mbps',
            onChanged: (v) => controller.setCustomBitrate(v.round()),
          ),

        const SectionHeader(title: 'Audio'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.normalizeLoudness,
          title: const Text('Platform loudness (−14 LUFS)'),
          subtitle: const Text(
            'Levels the mix to what YouTube and Spotify normalise to. '
            'Leave off if you balanced the mix by ear.',
          ),
          onChanged: (value) => controller.setNormalizeLoudness(value),
        ),
        LabeledSlider(
          label: 'Audio bitrate',
          value: settings.audioBitrateKbps.toDouble(),
          min: 64,
          max: 320,
          divisions: 8,
          formatter: (v) => '${v.round()} kbps',
          onChanged: (v) => controller.setAudioBitrate(v.round()),
        ),

        const SectionHeader(title: 'Performance'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Hardware encoding'),
          subtitle: const Text(
            'Much faster. ProCut retries in software automatically if the '
            'device encoder refuses the format.',
          ),
          value: settings.useHardwareEncoder,
          onChanged: controller.setHardwareEncoding,
        ),

        if (issues.isNotEmpty)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final issue in issues)
                    Text(
                      '• $issue',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ProgressView extends ConsumerWidget {
  const _ProgressView({required this.projectId, required this.progress});

  final String projectId;
  final ExportProgress progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(exportControllerProvider.notifier);
    final remaining = progress.estimatedTimeRemaining;

    return Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (progress.stage == ExportStage.completed)
            Icon(
              Icons.check_circle_rounded,
              size: 72,
              color: theme.colorScheme.secondary,
            )
          else if (progress.stage == ExportStage.failed)
            Icon(
              Icons.error_rounded,
              size: 72,
              color: theme.colorScheme.error,
            )
          else if (progress.stage == ExportStage.cancelled)
            Icon(
              Icons.cancel_rounded,
              size: 72,
              color: theme.colorScheme.onSurfaceVariant,
            )
          else
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: progress.progress <= 0 ? null : progress.progress,
                      strokeWidth: 6,
                    ),
                  ),
                  Text(
                    '${progress.percent}%',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),

          const SizedBox(height: Spacing.xl),
          Text(
            switch (progress.stage) {
              ExportStage.completed => 'Export complete',
              ExportStage.failed => 'Export failed',
              ExportStage.cancelled => 'Export cancelled',
              _ => progress.message ?? progress.stage.label,
            },
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),

          if (progress.errorMessage != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              progress.errorMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          if (!progress.isTerminal) ...[
            const SizedBox(height: Spacing.md),
            Text(
              [
                if (progress.speed > 0)
                  '${progress.speed.toStringAsFixed(1)}× realtime',
                if (remaining != null)
                  '${TimeUtils.formatShort(remaining)} left',
                if (progress.outputBytes > 0)
                  TimeUtils.formatBytes(progress.outputBytes),
              ].join('  ·  '),
              style: AppTheme.timecode(context, size: 12).copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          if (progress.isSuccess && progress.outputBytes > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              TimeUtils.formatBytes(progress.outputBytes),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          const SizedBox(height: Spacing.xxl),

          if (progress.isSuccess) ...[
            GradientButton(
              label: 'Save to gallery',
              icon: Icons.download_rounded,
              expand: true,
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final result = await controller.saveToGallery();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      result.isOk
                          ? 'Saved to your gallery'
                          : result.failureOrNull!.message,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: Spacing.md),
            OutlinedButton.icon(
              onPressed: () => controller.share(),
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Share'),
            ),
            const SizedBox(height: Spacing.sm),
            TextButton(
              onPressed: () {
                controller.reset();
                Navigator.of(context).maybePop();
              },
              child: const Text('Back to editor'),
            ),
          ] else if (progress.isTerminal) ...[
            GradientButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              expand: true,
              onPressed: controller.reset,
            ),
          ] else
            OutlinedButton.icon(
              onPressed: controller.cancel,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Cancel export'),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}


/// One line above the buttons: what the queue is doing, with a way in.
class _QueueSummary extends ConsumerWidget {
  const _QueueSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(exportQueueProvider);
    if (queue.jobs.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final running = queue.jobs
        .where((j) => j.status == QueuedExportStatus.running)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        onTap: () => _showQueue(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: Row(
            children: [
              if (running != null)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: running.progress <= 0 ? null : running.progress,
                  ),
                )
              else
                Icon(
                  Icons.playlist_play_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  running != null
                      ? 'Exporting ${running.label} — '
                            '${queue.remaining} in the queue'
                      : '${queue.jobs.length} job(s) in the queue',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const _QueueSheet(),
    );
  }
}

class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(exportQueueProvider);
    final theme = Theme.of(context);

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ref.watch(stringsProvider).exportQueue,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: queue.jobs.any((j) => j.isFinished)
                    ? ref.read(exportQueueProvider.notifier).clearFinished
                    : null,
                child: Text(ref.watch(stringsProvider).clearFinished),
              ),
            ],
          ),
          for (final job in queue.jobs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: switch (job.status) {
                QueuedExportStatus.waiting =>
                  const Icon(Icons.schedule_rounded),
                QueuedExportStatus.running => SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    value: job.progress <= 0 ? null : job.progress,
                  ),
                ),
                QueuedExportStatus.done => Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                ),
                QueuedExportStatus.failed => Icon(
                  Icons.error_rounded,
                  color: theme.colorScheme.error,
                ),
                QueuedExportStatus.cancelled =>
                  const Icon(Icons.cancel_outlined),
              },
              title: Text(job.label),
              subtitle: job.errorMessage != null
                  ? Text(
                      job.errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    )
                  : job.outputPath != null
                  ? Text(
                      job.outputPath!,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              trailing: switch (job.status) {
                QueuedExportStatus.waiting => IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () =>
                      ref.read(exportQueueProvider.notifier).remove(job.id),
                ),
                QueuedExportStatus.running => IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () => ref
                      .read(exportQueueProvider.notifier)
                      .cancelRunning(),
                ),
                _ => null,
              },
            ),
        ],
      ),
    );
  }
}


/// Which slice of the timeline to render, plus the test-render shortcut.
///
/// Null means the whole thing. Kept in its own provider rather than in export
/// settings because it is about *this* render, not a preference to persist —
/// nobody wants yesterday's in-point silently applied to today's export.
final exportRangeProvider = NotifierProvider<ExportRangeController, ExportRange?>(
  ExportRangeController.new,
);

class ExportRangeController extends Notifier<ExportRange?> {
  @override
  ExportRange? build() => null;

  void set(ExportRange? range) => state = range;
  void clear() => state = null;
}

class _RangeRow extends ConsumerWidget {
  const _RangeRow({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final range = ref.watch(exportRangeProvider);
    final editor = ref.watch(editorControllerProvider(projectId));
    final playhead = ref.watch(playheadControllerProvider);
    if (editor == null) return const SizedBox.shrink();

    final total = editor.timeline.duration;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              range == null
                  ? 'Rendering the whole timeline '
                        '(${TimeUtils.formatShort(total)})'
                  : 'Rendering ${TimeUtils.formatShort(range.start)}'
                        '–${TimeUtils.formatShort(range.end)} '
                        '(${TimeUtils.formatShort(range.duration)})',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (range != null)
            TextButton(
              onPressed: () => ref.read(exportRangeProvider.notifier).clear(),
              child: const Text('Whole'),
            ),
          TextButton(
            onPressed: () {
              // A ten-second window at the playhead: long enough to judge a
              // grade or a transition, short enough to sit through.
              ref.read(exportRangeProvider.notifier).set(
                    ExportRange.around(
                      playhead.position,
                      length: const Duration(seconds: 10),
                    ).clampedTo(total) ??
                        ExportRange(start: Duration.zero, end: total),
                  );
            },
            child: const Text('10s test'),
          ),
        ],
      ),
    );
  }
}
