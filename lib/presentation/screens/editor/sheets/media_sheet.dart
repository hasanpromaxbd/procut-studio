/// The project's media: what is in use, what is not, and what it all costs.
///
/// A long edit accumulates imports that no clip references any more, plus
/// derived files — proxies, waveforms, thumbnails — that are regenerable but
/// not free. Neither is visible anywhere else, so "why is this project 8 GB"
/// has no answer without this screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/utils/time_utils.dart';
import '../../../../domain/entities/media_asset.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';
import '../../settings/settings_screen.dart' show cacheSizeProvider;

class MediaSheet extends ConsumerStatefulWidget {
  const MediaSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<MediaSheet> createState() => _MediaSheetState();
}

class _MediaSheetState extends ConsumerState<MediaSheet> {
  /// Bytes on disk per asset, filled in as the sizes come back. Stat calls
  /// are cheap individually but not free in a loop, so the list renders
  /// immediately and the numbers arrive after.
  Map<String, int>? _sizes;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    final editor = ref.read(editorControllerProvider(widget.projectId));
    if (editor == null) return;

    final sizes = <String, int>{};
    for (final asset in editor.project.assets.values) {
      var bytes = 0;
      for (final path in [asset.path, if (asset.hasProxy) asset.proxyPath!]) {
        try {
          final file = File(path);
          if (file.existsSync()) bytes += file.lengthSync();
        } catch (_) {
          // A revoked SAF grant or a moved file: report what we can rather
          // than failing the whole listing.
        }
      }
      sizes[asset.id] = bytes;
    }
    if (mounted) setState(() => _sizes = sizes);
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorControllerProvider(widget.projectId));
    final theme = Theme.of(context);
    if (editor == null) return const SizedBox.shrink();

    final referenced = editor.project.referencedAssetIds;
    final assets = editor.project.assets.values.toList()
      ..sort((a, b) {
        // Unused first — they are what the user came here for.
        final aUsed = referenced.contains(a.id);
        final bUsed = referenced.contains(b.id);
        if (aUsed != bUsed) return aUsed ? 1 : -1;
        return (_sizes?[b.id] ?? 0).compareTo(_sizes?[a.id] ?? 0);
      });

    final unused = assets.where((a) => !referenced.contains(a.id)).toList();
    final total = _sizes?.values.fold<int>(0, (a, b) => a + b) ?? 0;
    final wasted = _sizes == null
        ? 0
        : unused.fold<int>(0, (sum, a) => sum + (_sizes![a.id] ?? 0));

    return ToolSheet(
      title: 'Media',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _sizes == null
                ? 'Measuring…'
                : '${assets.length} item(s), ${TimeUtils.formatBytes(total)} '
                      'on disk.',
            style: theme.textTheme.bodyMedium,
          ),

          if (unused.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${unused.length} item(s) no clip uses'
                        '${wasted > 0 ? ', ${TimeUtils.formatBytes(wasted)}' : ''}'
                        '. Removing them leaves the files on your device.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    FilledButton.tonal(
                      onPressed: () {
                        ref
                            .read(
                              editorControllerProvider(
                                widget.projectId,
                              ).notifier,
                            )
                            .pruneUnusedMedia();
                        unawaited(_measure());
                      },
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SectionHeader(title: 'In this project'),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: assets.length,
              itemBuilder: (context, index) {
                final asset = assets[index];
                final used = referenced.contains(asset.id);
                final bytes = _sizes?[asset.id];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (asset.kind) {
                      AssetKind.video => Icons.movie_rounded,
                      AssetKind.audio => Icons.music_note_rounded,
                      AssetKind.image => Icons.image_rounded,
                    },
                    color: used
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    asset.displayName.isEmpty
                        ? asset.path.split('/').last
                        : asset.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    [
                      if (!used) 'unused',
                      if (bytes != null) TimeUtils.formatBytes(bytes),
                      if (asset.hasProxy) 'proxy',
                      if (asset.duration > Duration.zero)
                        TimeUtils.formatShort(asset.duration),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                );
              },
            ),
          ),

          const SectionHeader(title: 'Regenerable files'),
          Text(
            'Proxies, waveforms and thumbnails are rebuilt on demand. '
            'Clearing them frees space now and costs a little time later.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.sm),
          Consumer(
            builder: (context, ref, _) {
              final cache = ref.watch(cacheSizeProvider);
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      cache.when(
                        data: (bytes) => TimeUtils.formatBytes(bytes),
                        loading: () => 'Measuring…',
                        error: (_, _) => 'Unknown',
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      await ref.read(mediaRepositoryProvider)
                          .clearDerivedCache();
                      ref.invalidate(cacheSizeProvider);
                    },
                    child: const Text('Clear'),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
