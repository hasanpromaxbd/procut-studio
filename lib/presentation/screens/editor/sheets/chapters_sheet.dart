/// Chapters: name them here, copy the timestamp list out.
///
/// Markers already exist and already have a chapter kind; what was missing was
/// the last mile — turning them into the text a video description actually
/// takes. Doing that by hand from a timeline is exactly the sort of transcription
/// nobody should be doing.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/marker.dart';
import '../../../../domain/usecases/chapter_export.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class ChaptersSheet extends ConsumerStatefulWidget {
  const ChaptersSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ChaptersSheet> createState() => _ChaptersSheetState();
}

class _ChaptersSheetState extends ConsumerState<ChaptersSheet> {
  ChapterFormat _format = ChapterFormat.youtube;
  final Map<String, TextEditingController> _names = {};

  @override
  void dispose() {
    for (final field in _names.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );
    final theme = Theme.of(context);
    if (editor == null) return const SizedBox.shrink();

    final chapters =
        editor.timeline.markers
            .where((m) => m.kind == MarkerKind.chapter)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));

    final text = ChapterExport.format(
      chapters,
      editor.timeline.duration,
      format: _format,
    );
    final problem = _format == ChapterFormat.youtube
        ? ChapterExport.youtubeProblem(chapters)
        : (chapters.isEmpty ? 'There are no chapter markers yet.' : null);

    return ToolSheet(
      title: 'Chapters',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => controller.addMarkerAtPlayhead(
              kind: MarkerKind.chapter,
              label: 'Chapter ${chapters.length + 1}',
            ),
            icon: const Icon(Icons.bookmark_add_rounded),
            label: const Text('Add a chapter here'),
          ),

          if (chapters.isNotEmpty) ...[
            const SectionHeader(title: 'Chapters'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  final field = _names.putIfAbsent(
                    chapter.id,
                    () => TextEditingController(text: chapter.label),
                  );
                  return Row(
                    children: [
                      TextButton(
                        onPressed: () => ref
                            .read(playheadControllerProvider.notifier)
                            .seek(chapter.time),
                        child: Text(
                          TimeUtils.formatShort(chapter.time),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: field,
                          style: theme.textTheme.bodyMedium,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Chapter name',
                          ),
                          onChanged: (value) =>
                              controller.renameMarker(chapter.id, value),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => controller.removeMarker(chapter.id),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],

          const SectionHeader(title: 'Copy out'),
          SegmentedButton<ChapterFormat>(
            segments: [
              for (final format in ChapterFormat.values)
                ButtonSegment(value: format, label: Text(format.label)),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (value) =>
                setState(() => _format = value.first),
          ),

          if (problem != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              problem,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],

          if (text.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
              ),
              child: SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
