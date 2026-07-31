/// The caption editor: every caption in one list.
///
/// Captions arrive thirty at a time from transcription, and fixing them one
/// selected clip at a time is the difference between the feature being usable
/// and not. Here they are a list you can read straight down — edit the text
/// in place, jump the playhead to a cue, merge two that were split
/// mid-sentence, and restyle or resync the whole set at once.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/text_style_spec.dart';
import '../../../../domain/entities/track.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../widgets/common/glass_panel.dart';

/// Ready-made looks. Each is a complete [TextStyleSpec] rather than a diff,
/// so applying one is predictable no matter what the captions looked like
/// before.
enum CaptionStyle {
  clean('Clean', 'White with a thin outline'),
  bold('Bold outline', 'Heavy text, thick black edge'),
  boxed('Boxed', 'Solid panel behind the words'),
  glow('Glow', 'Soft light behind the letters');

  const CaptionStyle(this.label, this.blurb);

  final String label;
  final String blurb;

  TextStyleSpec get spec => switch (this) {
    CaptionStyle.clean => const TextStyleSpec(
      fontSize: 0.045,
      fontWeight: 600,
      strokeWidth: 0.04,
      alignment: TextAlignment.center,
    ),
    CaptionStyle.bold => const TextStyleSpec(
      fontSize: 0.055,
      fontWeight: 800,
      strokeWidth: 0.12,
      allCaps: true,
      alignment: TextAlignment.center,
    ),
    CaptionStyle.boxed => const TextStyleSpec(
      fontSize: 0.042,
      fontWeight: 700,
      backgroundColor: 0xCC000000,
      backgroundPadding: 0.016,
      backgroundRadius: 0.012,
      alignment: TextAlignment.center,
    ),
    CaptionStyle.glow => const TextStyleSpec(
      fontSize: 0.05,
      fontWeight: 700,
      glowRadius: 0.35,
      glowColor: 0xFF7C5CFF,
      strokeWidth: 0.03,
      alignment: TextAlignment.center,
    ),
  };
}

class CaptionSheet extends ConsumerStatefulWidget {
  const CaptionSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<CaptionSheet> createState() => _CaptionSheetState();
}

class _CaptionSheetState extends ConsumerState<CaptionSheet> {
  /// One controller per caption, kept alive across rebuilds so typing does
  /// not lose the caret every time the timeline changes.
  final Map<String, TextEditingController> _fields = {};

  @override
  void dispose() {
    for (final field in _fields.values) {
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

    final captions = <TextClip>[
      for (final track in editor?.timeline.tracks ?? const <Track>[])
        for (final clip in track.clips)
          if (clip is TextClip && clip.isSubtitle) clip,
    ]..sort((a, b) => a.start.compareTo(b.start));

    return ToolSheet(
      title: 'Captions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (captions.isEmpty)
            Text(
              'No captions yet — run Auto captions from the AI tools.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            const SectionHeader(title: 'Style them all'),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final style in CaptionStyle.values)
                  ActionChip(
                    label: Text(style.label),
                    tooltip: style.blurb,
                    onPressed: () => controller.restyleCaptions(style.spec),
                  ),
              ],
            ),

            const SectionHeader(title: 'Sync'),
            Row(
              children: [
                Text(
                  'Shift every caption',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                for (final ms in [-500, -100, 100, 500])
                  Padding(
                    padding: const EdgeInsets.only(left: Spacing.xs),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        '${ms > 0 ? '+' : ''}${(ms / 1000).toStringAsFixed(1)}s',
                      ),
                      onPressed: () => controller.nudgeCaptions(
                        Duration(milliseconds: ms),
                      ),
                    ),
                  ),
              ],
            ),

            SectionHeader(
              title: '${captions.length} caption(s)',
              trailing: Text(
                'tap a time to jump',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: captions.length,
                itemBuilder: (context, index) {
                  final caption = captions[index];
                  final field = _fields.putIfAbsent(
                    caption.id,
                    () => TextEditingController(text: caption.text),
                  );
                  // Keep an untouched field in step with edits made elsewhere
                  // without stamping on the caret of one being typed in.
                  if (field.text != caption.text &&
                      !(field.selection.isValid &&
                          field.selection.isCollapsed == false)) {
                    field.value = TextEditingValue(
                      text: caption.text,
                      selection: TextSelection.collapsed(
                        offset: caption.text.length.clamp(
                          0,
                          caption.text.length,
                        ),
                      ),
                    );
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () {
                            ref
                                .read(playheadControllerProvider.notifier)
                                .seek(caption.start);
                            controller.select(caption.id);
                          },
                          child: Text(
                            TimeUtils.formatShort(caption.start),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: field,
                            style: theme.textTheme.bodyMedium,
                            maxLines: null,
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              // A machine transcription flags what it was
                              // unsure of; surface that here so the review
                              // pass knows where to look.
                              suffixIcon: caption.label == 'check'
                                  ? Icon(
                                      Icons.help_outline_rounded,
                                      size: 16,
                                      color: theme.colorScheme.error,
                                    )
                                  : null,
                            ),
                            onChanged: (value) => controller.updateTextClip(
                              caption.id,
                              text: value,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Merge with the next caption',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.merge_rounded, size: 18),
                          onPressed: index == captions.length - 1
                              ? null
                              : () => controller.mergeCaption(caption.id),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],

          if (editor?.errorMessage != null) ...[
            const SizedBox(height: Spacing.sm),
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
}

/// Opens the caption editor.
Future<void> showCaptionSheet(BuildContext context, String projectId) =>
    ToolSheet.show<void>(context, sheet: CaptionSheet(projectId: projectId));

/// Kept so callers do not have to import `dart:async` just to fire and forget.
void openCaptionSheet(BuildContext context, String projectId) =>
    unawaited(showCaptionSheet(context, projectId));
