/// The jump-cut assistant: find the dead air, show it, cut it.
///
/// Same two-step contract as the beat cutter: detection produces a list you
/// can read and prune, and only the approved list is cut — in one undo step.
/// The lead number is time saved, because "removes 41s of dead air" is the
/// entire reason to open this sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../engine/audio/silence_detector.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class JumpCutSheet extends ConsumerStatefulWidget {
  const JumpCutSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<JumpCutSheet> createState() => _JumpCutSheetState();
}

class _JumpCutSheetState extends ConsumerState<JumpCutSheet> {
  double _threshold = 0.12;
  double _minSilenceMs = 450;
  bool _detecting = false;
  List<SilenceSpan>? _spans;
  final Set<int> _excluded = {};

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);
    final spans = _spans;
    final kept = spans == null
        ? const <SilenceSpan>[]
        : [
            for (var i = 0; i < spans.length; i++)
              if (!_excluded.contains(i)) spans[i],
          ];
    final saved = SilenceDetector.totalRemoved(kept);

    return ToolSheet(
      title: 'Jump cut',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Finds the silences in the selected clip and cuts them out, '
            'closing every gap — the talking-head edit, automated.',
            style: theme.textTheme.bodySmall,
          ),

          const SectionHeader(title: 'Sensitivity'),
          _LabelledSlider(
            label: 'Quieter than',
            value: _threshold,
            min: 0.04,
            max: 0.35,
            format: (v) => '${(v * 100).round()}% of speech',
            onChanged: (v) => setState(() {
              _threshold = v;
              _spans = null;
            }),
          ),
          _LabelledSlider(
            label: 'For at least',
            value: _minSilenceMs,
            min: 200,
            max: 2000,
            format: (v) => '${(v / 1000).toStringAsFixed(1)}s',
            onChanged: (v) => setState(() {
              _minSilenceMs = v;
              _spans = null;
            }),
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
                : const Icon(Icons.search_rounded),
            label: Text(_detecting ? 'Listening…' : 'Find silences'),
          ),

          if (spans != null) ...[
            const SectionHeader(title: 'Found'),
            if (spans.isEmpty)
              Text(
                'No silences at this sensitivity. Raise it, or the take is '
                'genuinely tight.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(
                'Cutting ${kept.length} of ${spans.length} silences '
                'removes ${TimeUtils.formatShort(saved)}. '
                'Tap one to keep it.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  for (var i = 0; i < spans.length; i++)
                    FilterChip(
                      selected: !_excluded.contains(i),
                      label: Text(
                        '${TimeUtils.formatShort(spans[i].start)} · '
                        '${TimeUtils.formatShort(spans[i].length)}',
                      ),
                      onSelected: (_) => setState(() {
                        if (!_excluded.remove(i)) _excluded.add(i);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              FilledButton.icon(
                onPressed: kept.isEmpty ? null : () => _apply(kept),
                icon: const Icon(Icons.content_cut_rounded),
                label: Text(
                  'Cut ${kept.length} silence(s) · '
                  'save ${TimeUtils.formatShort(saved)}',
                ),
              ),
            ],
          ],

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

  Future<void> _detect() async {
    setState(() {
      _detecting = true;
      _excluded.clear();
    });
    try {
      final spans = await ref
          .read(editorControllerProvider(widget.projectId).notifier)
          .detectSilences(
            threshold: _threshold,
            minSilence: Duration(milliseconds: _minSilenceMs.round()),
          );
      if (mounted) setState(() => _spans = spans);
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _apply(List<SilenceSpan> spans) {
    ref
        .read(editorControllerProvider(widget.projectId).notifier)
        .removeSilences(spans);
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _spans = null);
  }
}

class _LabelledSlider extends StatelessWidget {
  const _LabelledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(width: 92, child: Text(label, style: theme.textTheme.bodySmall)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 96,
          child: Text(
            format(value),
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
