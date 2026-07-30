/// The edit history, as a list you can jump around in.
///
/// Undo/redo buttons walk one step; this shows the whole road. Every entry is
/// an edit the user made, in order, with "now" marked — tapping any of them
/// jumps there, and nothing is lost by jumping: going back leaves the redo
/// stack intact, so the future is still reachable until a new edit forks it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class HistorySheet extends ConsumerWidget {
  const HistorySheet({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(editorControllerProvider(projectId));
    final theme = Theme.of(context);
    if (editor == null) return const SizedBox.shrink();

    // Oldest first, reading down the list like a log:
    //   undo entries → the current state → redo entries.
    // An undo entry's label names the edit that *produced the next state*, so
    // the row text pairs each label with where tapping it takes you.
    final undo = editor.undoStack;
    final redo = editor.redoStack.reversed.toList();

    final rows = <_HistoryRow>[
      _HistoryRow(
        label: 'Opened',
        steps: undo.length,
        isCurrent: undo.isEmpty,
      ),
      for (var i = 0; i < undo.length; i++)
        _HistoryRow(
          label: undo[i].label,
          steps: undo.length - 1 - i,
          isCurrent: false,
        ),
      if (undo.isNotEmpty)
        _HistoryRow(
          label: editor.undoLabel ?? 'now',
          steps: 0,
          isCurrent: true,
        ),
      for (var i = 0; i < redo.length; i++)
        _HistoryRow(
          label: redo[i].label,
          steps: -(i + 1),
          isCurrent: false,
        ),
    ];

    // Collapse the duplicate row the mapping above produces when the undo
    // stack is empty and "Opened" already is the current state.
    final deduped = <_HistoryRow>[];
    for (final row in rows) {
      if (deduped.isNotEmpty &&
          deduped.last.steps == row.steps &&
          deduped.last.isCurrent == row.isCurrent) {
        continue;
      }
      deduped.add(row);
    }

    return ToolSheet(
      title: 'History',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${undo.length} edit(s) behind, ${redo.length} ahead. Jumping '
            'back keeps the future until you edit again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: deduped.length,
              itemBuilder: (context, index) {
                final row = deduped[index];
                final future = row.steps < 0;
                return ListTile(
                  dense: true,
                  selected: row.isCurrent,
                  leading: Icon(
                    row.isCurrent
                        ? Icons.radio_button_checked_rounded
                        : future
                        ? Icons.redo_rounded
                        : Icons.circle_outlined,
                    size: 18,
                    color: row.isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    row.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: future
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                      fontWeight: row.isCurrent ? FontWeight.w600 : null,
                    ),
                  ),
                  trailing: row.isCurrent
                      ? Text('now', style: theme.textTheme.labelSmall)
                      : null,
                  onTap: row.isCurrent
                      ? null
                      : () => ref
                            .read(editorControllerProvider(projectId).notifier)
                            .jumpHistory(row.steps),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow {
  const _HistoryRow({
    required this.label,
    required this.steps,
    required this.isCurrent,
  });

  final String label;

  /// Undos (positive) or redos (negative) needed to reach this state.
  final int steps;
  final bool isCurrent;
}
