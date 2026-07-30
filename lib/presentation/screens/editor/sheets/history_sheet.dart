/// The edit history, as a list you can jump around in.
///
/// Undo/redo buttons walk one step; this shows the whole road. Every entry is
/// an edit the user made, in order, with "now" marked — tapping any of them
/// jumps there, and nothing is lost by jumping: going back leaves the redo
/// stack intact, so the future is still reachable until a new edit forks it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class HistorySheet extends ConsumerStatefulWidget {
  const HistorySheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<HistorySheet> {
  List<DateTime>? _versions;

  String get projectId => widget.projectId;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref
          .read(editorControllerProvider(widget.projectId).notifier)
          .listVersions()
          .then((versions) {
            if (mounted) setState(() => _versions = versions);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            constraints: const BoxConstraints(maxHeight: 300),
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
          if (_versions != null && _versions!.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text('Saved versions', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              'Snapshots taken on every save, beyond this session\u2019s '
              'undo. Restoring saves the current state first, so nothing is '
              'lost either way.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            for (final (index, stamp) in _versions!.indexed)
              ListTile(
                dense: true,
                leading: const Icon(Icons.restore_rounded, size: 18),
                title: Text('$stamp'.split('.').first),
                trailing: TextButton(
                  onPressed: () => unawaited(_restore(index)),
                  child: const Text('Restore'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _restore(int index) async {
    final ok = await ref
        .read(editorControllerProvider(projectId).notifier)
        .restoreVersion(index);
    if (ok && mounted) Navigator.of(context).pop();
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
