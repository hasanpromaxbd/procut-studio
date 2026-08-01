/// A short introduction to the editor, shown once.
///
/// The tool rail has grown to roughly thirty entries. That is fine for
/// someone who watched it grow and hostile to someone opening it for the
/// first time — the useful five are indistinguishable from the specialist
/// twenty-five. This names the five and gets out of the way.
///
/// Shown once, never nagged, and skippable at the first tap. A tour that
/// reappears is worse than no tour.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/theme/app_dimens.dart';

/// Whether the tour has been seen. Persisted, because "once" has to survive
/// closing the app.
final tourSeenProvider = NotifierProvider<TourSeenController, bool>(
  TourSeenController.new,
);

class TourSeenController extends Notifier<bool> {
  static const _key = 'tourSeen';

  @override
  bool build() => ref.read(hiveStoreProvider).settings.get(_key) == 'true';

  /// Lets the user ask for the tour again from Settings.
  void reset() {
    state = false;
    unawaited(ref.read(hiveStoreProvider).settings.put(_key, 'false'));
  }

  void markSeen() {
    if (state) return;
    state = true;
    unawaited(ref.read(hiveStoreProvider).settings.put(_key, 'true'));
  }
}

class _Step {
  const _Step(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const _steps = [
  _Step(
    Icons.add_photo_alternate_outlined,
    'Media',
    'Bring in video, photos and music. Big files get a lightweight preview '
        'copy automatically, so scrubbing stays smooth.',
  ),
  _Step(
    Icons.content_cut_rounded,
    'Split',
    'Put the playhead where you want a cut and split. Select several clips '
        'and every tool acts on all of them.',
  ),
  _Step(
    Icons.auto_fix_high_rounded,
    'Effects and Curves',
    'Effects, colour and masks live together. Anything you keyframe can be '
        'shaped in Curves afterwards.',
  ),
  _Step(
    Icons.closed_caption_rounded,
    'Captions',
    'Auto-caption from the AI tools, then fix them all in one list rather '
        'than one clip at a time.',
  ),
  _Step(
    Icons.ios_share_rounded,
    'Export',
    'Pick a platform preset, or render just ten seconds first to check it '
        'before committing to the whole thing.',
  ),
];

/// Shows the tour if it has not been seen. Safe to call on every open.
Future<void> maybeShowTour(BuildContext context, WidgetRef ref) async {
  if (ref.read(tourSeenProvider)) return;
  // Mark it seen before showing, not after: a crash mid-tour must not mean
  // the user meets it again every launch.
  ref.read(tourSeenProvider.notifier).markSeen();

  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _TourSheet(),
  );
}

class _TourSheet extends StatefulWidget {
  const _TourSheet();

  @override
  State<_TourSheet> createState() => _TourSheetState();
}

class _TourSheetState extends State<_TourSheet> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _page == _steps.length - 1;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A quick tour', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              'Five things worth knowing. Everything else can wait.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.lg),

            SizedBox(
              height: 190,
              child: PageView.builder(
                controller: _pages,
                itemCount: _steps.length,
                onPageChanged: (index) => setState(() => _page = index),
                itemBuilder: (context, index) {
                  final step = _steps[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        step.icon,
                        size: 34,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: Spacing.md),
                      Text(step.title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: Spacing.sm),
                      Text(step.body, style: theme.textTheme.bodyMedium),
                    ],
                  );
                },
              ),
            ),

            Row(
              children: [
                for (var i = 0; i < _steps.length; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
                const SizedBox(width: Spacing.sm),
                FilledButton(
                  onPressed: () {
                    if (last) {
                      Navigator.of(context).pop();
                    } else {
                      _pages.nextPage(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  child: Text(last ? 'Start editing' : 'Next'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
