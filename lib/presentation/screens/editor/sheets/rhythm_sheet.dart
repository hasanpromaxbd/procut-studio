/// Beat detection and beat-synced cutting.
///
/// Two steps, deliberately separate: detection drops markers you can see and
/// nudge, and only then does cutting act on them. A one-button "auto beat cut"
/// that silently razors thirty times is impossible to trust or correct.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/marker.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class RhythmSheet extends ConsumerStatefulWidget {
  const RhythmSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<RhythmSheet> createState() => _RhythmSheetState();
}

class _RhythmSheetState extends ConsumerState<RhythmSheet> {
  int _everyNth = 1;
  bool _detecting = false;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);

    final beats = editor?.timeline.markers
            .where((m) => m.kind == MarkerKind.beat)
            .toList() ??
        const <Marker>[];
    final selected = editor?.selectedClipIds.length ?? 0;
    final cuts = beats.isEmpty ? 0 : (beats.length / _everyNth).ceil();

    return ToolSheet(
      title: 'Cut to the beat',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '1 · Find the beats'),
          Text(
            'Select the music clip and detect. Beats land on the timeline as '
            'markers you can see, move or delete before cutting anything.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          FilledButton.tonalIcon(
            onPressed: _detecting || editor?.selectedClipId == null
                ? null
                : _detect,
            icon: _detecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.graphic_eq_rounded),
            label: Text(_detecting ? 'Listening…' : 'Detect beats'),
          ),

          if (beats.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              '${beats.length} beats found · ${_tempoLabel(beats)}',
              style: theme.textTheme.bodyMedium,
            ),
          ],

          const SectionHeader(title: '2 · Cut on them'),
          Text(
            'Every beat is a cut twice a second at most tempos. Taking every '
            'second or fourth beat picks out the bar instead.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            children: [
              for (final n in [1, 2, 4, 8])
                ChoiceChip(
                  selected: _everyNth == n,
                  label: Text(n == 1 ? 'Every beat' : 'Every $n'),
                  onSelected: (_) => setState(() => _everyNth = n),
                ),
            ],
          ),

          const SizedBox(height: Spacing.md),
          Text(
            selected == 0
                ? 'Nothing selected — this will cut every clip the beats cross.'
                : 'Cutting $selected selected clip(s).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: Spacing.md),
          FilledButton.icon(
            onPressed: beats.isEmpty ? null : _cut,
            icon: const Icon(Icons.content_cut_rounded),
            label: Text(
              beats.isEmpty ? 'Cut on beats' : 'Cut at $cuts point(s)',
            ),
          ),

          if (editor?.errorMessage != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              editor!.errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Median interval → BPM. The median rather than the mean because one missed
  /// beat doubles an interval and would drag an average badly off.
  static String _tempoLabel(List<Marker> beats) {
    if (beats.length < 3) return 'tempo unknown';
    final times = beats.map((b) => b.time).toList()..sort();
    final gaps = <int>[
      for (var i = 1; i < times.length; i++)
        (times[i] - times[i - 1]).inMicroseconds,
    ]..sort();
    final median = gaps[gaps.length ~/ 2];
    if (median <= 0) return 'tempo unknown';
    return '${(60000000 / median).round()} BPM';
  }

  Future<void> _detect() async {
    setState(() => _detecting = true);
    try {
      await ref
          .read(editorControllerProvider(widget.projectId).notifier)
          .markBeats();
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _cut() {
    final added = ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .cutOnBeats(everyNth: _everyNth);
    if (added > 0) {
      unawaited(HapticFeedback.mediumImpact());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$added new clip(s) from $added cut(s)')),
        );
      }
    }
  }
}
