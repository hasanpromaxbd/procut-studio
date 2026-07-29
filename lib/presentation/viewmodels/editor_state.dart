/// Editor state and its undo history.
///
/// The playhead is deliberately **not** in here. It changes 60 times a second
/// during playback, and every listener of this state would rebuild with it.
/// It lives in its own notifier so the timeline ruler repaints while the
/// inspector, toolbar and clip list stay untouched.
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/entities/clip.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/timeline.dart';

/// One reversible step. Storing whole timelines is fine: they are immutable, so
/// an undo entry shares almost all of its structure with its neighbours and
/// costs a handful of pointers, not a deep copy.
@immutable
class UndoEntry {
  const UndoEntry({
    required this.timeline,
    required this.label,
    this.selectedClipIds = const {},
  });

  final Timeline timeline;

  /// Shown in the undo tooltip — "Undo split" beats "Undo".
  final String label;

  /// Restoring the selection with the timeline is what makes undo feel like
  /// stepping back rather than teleporting.
  final Set<String> selectedClipIds;
}

enum EditorTool {
  select('Select'),
  trim('Trim'),
  text('Text'),
  effects('Effects'),
  audio('Audio'),
  transform('Transform');

  const EditorTool(this.label);
  final String label;
}

@immutable
class EditorState {
  const EditorState({
    required this.project,
    this.selectedClipIds = const {},
    this.selectedTrackId,
    this.clipboard = const [],
    this.activeTool = EditorTool.select,
    this.undoStack = const [],
    this.redoStack = const [],
    this.isDirty = false,
    this.isSaving = false,
    this.isBusy = false,
    this.busyMessage,
    this.errorMessage,
    this.statusMessage,
  });

  final Project project;

  /// Selected clips. A set rather than one id because every structural edit
  /// (delete, move, effects) reads better applied to a selection than looped
  /// over by the caller.
  final Set<String> selectedClipIds;

  /// The primary selection — the one the inspector edits. Multi-select acts on
  /// the whole set; single-clip panels act on this.
  String? get selectedClipId =>
      selectedClipIds.isEmpty ? null : selectedClipIds.first;

  bool isSelected(String clipId) => selectedClipIds.contains(clipId);

  bool get hasMultipleSelected => selectedClipIds.length > 1;

  final String? selectedTrackId;

  /// Copied clips, kept in timeline order so paste preserves their spacing.
  final List<Clip> clipboard;

  bool get canPaste => clipboard.isNotEmpty;
  final EditorTool activeTool;

  final List<UndoEntry> undoStack;
  final List<UndoEntry> redoStack;

  final bool isDirty;
  final bool isSaving;

  /// A long operation (AI, proxy build) is running; the UI shows a blocking
  /// overlay with [busyMessage].
  final bool isBusy;
  final String? busyMessage;

  /// Transient banners. Cleared by the UI once shown.
  final String? errorMessage;
  final String? statusMessage;

  Timeline get timeline => project.timeline;
  Duration get duration => timeline.duration;

  bool get canUndo => undoStack.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;

  String? get undoLabel => undoStack.isEmpty ? null : undoStack.last.label;
  String? get redoLabel => redoStack.isEmpty ? null : redoStack.last.label;

  bool get hasSelection => selectedClipIds.isNotEmpty;

  /// Every selected clip that still exists, in timeline order.
  List<Clip> get selectedClips {
    final found = <Clip>[];
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        if (selectedClipIds.contains(clip.id)) found.add(clip);
      }
    }
    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  /// The selected clip, or null. Resolved on demand rather than cached, so it
  /// can never go stale against the timeline.
  (dynamic track, dynamic clip)? get selection {
    final id = selectedClipId;
    if (id == null) return null;
    return timeline.findClip(id);
  }

  EditorState copyWith({
    Project? project,
    Set<String>? selectedClipIds,
    String? selectedTrackId,
    List<Clip>? clipboard,
    EditorTool? activeTool,
    List<UndoEntry>? undoStack,
    List<UndoEntry>? redoStack,
    bool? isDirty,
    bool? isSaving,
    bool? isBusy,
    String? busyMessage,
    String? errorMessage,
    String? statusMessage,
    bool clearSelection = false,
    bool clearMessages = false,
  }) => EditorState(
    project: project ?? this.project,
    selectedClipIds:
        clearSelection ? const {} : (selectedClipIds ?? this.selectedClipIds),
    selectedTrackId: clearSelection ? null : (selectedTrackId ?? this.selectedTrackId),
    clipboard: clipboard ?? this.clipboard,
    activeTool: activeTool ?? this.activeTool,
    undoStack: undoStack ?? this.undoStack,
    redoStack: redoStack ?? this.redoStack,
    isDirty: isDirty ?? this.isDirty,
    isSaving: isSaving ?? this.isSaving,
    isBusy: isBusy ?? this.isBusy,
    busyMessage: isBusy == false ? null : (busyMessage ?? this.busyMessage),
    errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
    statusMessage: clearMessages ? null : (statusMessage ?? this.statusMessage),
  );

  /// Pushes the current timeline onto the undo stack and installs [next].
  EditorState withEdit(Timeline next, String label) {
    final entry = UndoEntry(
      timeline: timeline,
      label: label,
      selectedClipIds: selectedClipIds,
    );
    final stack = [...undoStack, entry];
    // Bound the history — a long session with a big timeline would otherwise
    // hold every intermediate state alive.
    final trimmed = stack.length > AppConstants.undoStackLimit
        ? stack.sublist(stack.length - AppConstants.undoStackLimit)
        : stack;

    return copyWith(
      project: project.withTimeline(next),
      undoStack: trimmed,
      redoStack: const [], // a new edit invalidates the redo branch
      isDirty: true,
      clearMessages: true,
    );
  }

  /// Replaces the timeline without touching history. For continuous gestures:
  /// a drag pushes one undo entry when it starts, then streams updates through
  /// here so the user does not have to press undo forty times.
  EditorState withLiveEdit(Timeline next) =>
      copyWith(project: project.withTimeline(next), isDirty: true);
}
