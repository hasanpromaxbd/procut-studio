/// Keyboard shortcuts for the editor.
///
/// Wrapping the whole editor in `CallbackShortcuts` rather than an
/// Actions/Intent tree: the bindings all target one controller, nothing needs
/// to be overridden per-widget, and the flat table below doubles as the data
/// for the cheat sheet — one list, two uses, impossible for them to disagree.
///
/// Text fields still win: `CallbackShortcuts` only fires when the focused
/// widget does not consume the key, so typing a clip label never splits it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../viewmodels/editor_controller.dart';
import '../../viewmodels/playhead_controller.dart';

/// One shortcut: the keys, what it does, and the words for the cheat sheet.
class EditorShortcut {
  const EditorShortcut({
    required this.activator,
    required this.keys,
    required this.label,
    required this.run,
  });

  final ShortcutActivator activator;

  /// Human-readable keys, e.g. `Ctrl+Z`.
  final String keys;
  final String label;
  final void Function(WidgetRef ref, String projectId) run;
}

/// The single source of truth for both the bindings and the help sheet.
List<EditorShortcut> editorShortcuts = [
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.space),
    keys: 'Space',
    label: 'Play / pause',
    run: (ref, _) => ref.read(playheadControllerProvider.notifier).togglePlay(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyS),
    keys: 'S',
    label: 'Split at the playhead',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).splitAtPlayhead(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.delete),
    keys: 'Delete',
    label: 'Delete selection',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).deleteSelected(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.backspace),
    keys: 'Backspace',
    label: 'Delete selection',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).deleteSelected(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    keys: 'Ctrl+Z',
    label: 'Undo',
    run: (ref, id) => ref.read(editorControllerProvider(id).notifier).undo(),
  ),
  EditorShortcut(
    activator: const SingleActivator(
      LogicalKeyboardKey.keyZ,
      control: true,
      shift: true,
    ),
    keys: 'Ctrl+Shift+Z',
    label: 'Redo',
    run: (ref, id) => ref.read(editorControllerProvider(id).notifier).redo(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyC, control: true),
    keys: 'Ctrl+C',
    label: 'Copy selection',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).copySelection(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyV, control: true),
    keys: 'Ctrl+V',
    label: 'Paste at the playhead',
    run: (ref, id) => ref.read(editorControllerProvider(id).notifier).paste(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyD, control: true),
    keys: 'Ctrl+D',
    label: 'Duplicate selection',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).duplicateSelected(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyA, control: true),
    keys: 'Ctrl+A',
    label: 'Select everything',
    run: (ref, id) =>
        ref.read(editorControllerProvider(id).notifier).selectAll(),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.arrowLeft),
    keys: '←',
    label: 'Back one frame',
    run: (ref, _) =>
        ref.read(playheadControllerProvider.notifier).stepFrames(-1),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.arrowRight),
    keys: '→',
    label: 'Forward one frame',
    run: (ref, _) =>
        ref.read(playheadControllerProvider.notifier).stepFrames(1),
  ),
  EditorShortcut(
    activator: const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      shift: true,
    ),
    keys: 'Shift+←',
    label: 'Back one second',
    run: (ref, _) => ref
        .read(playheadControllerProvider.notifier)
        .seekBy(const Duration(seconds: -1)),
  ),
  EditorShortcut(
    activator: const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      shift: true,
    ),
    keys: 'Shift+→',
    label: 'Forward one second',
    run: (ref, _) => ref
        .read(playheadControllerProvider.notifier)
        .seekBy(const Duration(seconds: 1)),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.home),
    keys: 'Home',
    label: 'Jump to the start',
    run: (ref, _) =>
        ref.read(playheadControllerProvider.notifier).seek(Duration.zero),
  ),
  EditorShortcut(
    activator: const SingleActivator(LogicalKeyboardKey.keyM),
    keys: 'M',
    label: 'Drop a marker',
    run: (ref, id) => ref
        .read(editorControllerProvider(id).notifier)
        .addMarkerAtPlayhead(),
  ),
];

/// Wraps [child] with the bindings. Sits above the Scaffold so the shortcuts
/// work wherever focus happens to be, except inside text input.
class EditorShortcutsScope extends ConsumerWidget {
  const EditorShortcutsScope({
    required this.projectId,
    required this.child,
    super.key,
  });

  final String projectId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: {
      for (final shortcut in editorShortcuts)
        shortcut.activator: () => shortcut.run(ref, projectId),
      const SingleActivator(LogicalKeyboardKey.slash, shift: true): () =>
          showShortcutsSheet(context),
    },
    // Focus so the scope receives keys at all — autofocus, but a text field
    // grabbing focus later still takes priority, which is the right order.
    child: Focus(autofocus: true, child: child),
  );
}

/// The cheat sheet, generated from the same table as the bindings.
void showShortcutsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            0,
            Spacing.lg,
            Spacing.lg,
          ),
          children: [
            Text('Keyboard shortcuts', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              'For tablets and desktops with a keyboard attached. '
              'Shift+? opens this list.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.md),
            for (final shortcut in editorShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        shortcut.label,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(Radii.xs),
                        ),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.sm,
                          vertical: 2,
                        ),
                        child: Text(
                          shortcut.keys,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}
