/// The scopes panel: histogram, waveform, RGB parade, vectorscope.
///
/// Painted from the textures `ScopesController` renders off the preview
/// raster. The panel is honest about its provenance — it measures the preview
/// as displayed, not the decoded source, and says so in the footer.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../viewmodels/playhead_controller.dart';
import '../../../viewmodels/scopes_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class ScopesSheet extends ConsumerStatefulWidget {
  const ScopesSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ScopesSheet> createState() => _ScopesSheetState();
}

class _ScopesSheetState extends ConsumerState<ScopesSheet> {
  @override
  void initState() {
    super.initState();
    // First reading on open — the user came here to see this frame.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(ref.read(scopesProvider.notifier).sampleNow()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scopes = ref.watch(scopesProvider);
    final theme = Theme.of(context);

    // Re-sample when the playhead settles somewhere new while live.
    ref.listen(playheadControllerProvider, (previous, next) {
      if (scopes.isLive && previous?.position != next.position) {
        ref.read(scopesProvider.notifier).requestSample();
      }
    });

    final data = scopes.data;

    return ToolSheet(
      title: 'Scopes',
      actions: [
        IconButton(
          tooltip: scopes.isLive ? 'Hold this reading' : 'Follow the playhead',
          isSelected: scopes.isLive,
          icon: Icon(
            scopes.isLive ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          onPressed: () =>
              ref.read(scopesProvider.notifier).setLive(live: !scopes.isLive),
        ),
        IconButton(
          tooltip: 'Measure this frame',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () =>
              unawaited(ref.read(scopesProvider.notifier).sampleNow()),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<ScopeKind>(
            segments: [
              for (final kind in ScopeKind.values)
                ButtonSegment(value: kind, label: Text(kind.label)),
            ],
            selected: {scopes.kind},
            showSelectedIcon: false,
            onSelectionChanged: (value) =>
                ref.read(scopesProvider.notifier).setKind(value.first),
          ),
          const SizedBox(height: Spacing.sm),
          Text(scopes.kind.blurb, style: theme.textTheme.bodySmall),
          const SizedBox(height: Spacing.md),

          AspectRatio(
            aspectRatio: scopes.kind == ScopeKind.vectorscope ? 1 : 16 / 9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: const BorderRadius.all(
                  Radius.circular(Radii.sm),
                ),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
                child: data == null
                    ? Center(
                        child: scopes.isSampling
                            ? const CircularProgressIndicator()
                            : Text(
                                scopes.error ?? 'No reading yet.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                      )
                    : CustomPaint(
                        painter: _ScopePainter(kind: scopes.kind, data: data),
                        child: const SizedBox.expand(),
                      ),
              ),
            ),
          ),

          if (data != null) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                _ClipChip(
                  label: 'highlights',
                  fraction: data.clippedHighlights,
                  theme: theme,
                ),
                const SizedBox(width: Spacing.sm),
                _ClipChip(
                  label: 'shadows',
                  fraction: data.clippedShadows,
                  theme: theme,
                ),
                const Spacer(),
                if (scopes.isSampling)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],

          const SizedBox(height: Spacing.sm),
          Text(
            'Measured from the preview as shown, effects included. The export '
            'is encoded from the source, so treat these as a guide, not a '
            'broadcast meter.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The clipping readout is a traffic light: green under 1%, amber under 5%,
/// red beyond — thresholds where lost detail starts to be visible on a phone.
class _ClipChip extends StatelessWidget {
  const _ClipChip({
    required this.label,
    required this.fraction,
    required this.theme,
  });

  final String label;
  final double fraction;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final percent = fraction * 100;
    final colour = percent < 1
        ? theme.colorScheme.primary
        : percent < 5
        ? const Color(0xFFE0A030)
        : theme.colorScheme.error;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.circle, size: 10, color: colour),
      label: Text(
        '${percent < 0.05 ? '0' : percent.toStringAsFixed(1)}% $label',
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _ScopePainter extends CustomPainter {
  const _ScopePainter({required this.kind, required this.data});

  final ScopeKind kind;
  final ScopesData data;

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case ScopeKind.histogram:
        _paintHistogram(canvas, size);
      case ScopeKind.waveform:
        _paintTexture(canvas, size, data.waveform);
      case ScopeKind.parade:
        _paintTexture(canvas, size, data.parade);
      case ScopeKind.vectorscope:
        _paintTexture(canvas, size, data.vectorscope);
        _paintVectorGraticule(canvas, size);
    }
  }

  void _paintTexture(Canvas canvas, Size size, ui.Image? image) {
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  /// Luma as a filled outline with the three channels overlaid additively —
  /// the layout every photo app has taught people to read.
  void _paintHistogram(Canvas canvas, Size size) {
    final peak = data.peakBin.toDouble();

    void channel(List<int> bins, Color colour, {bool fill = false}) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < 256; i++) {
        final x = (i / 255) * size.width;
        final y = size.height * (1 - (bins[i] / peak).clamp(0.0, 1.0));
        path.lineTo(x, y);
      }
      path.lineTo(size.width, size.height);
      if (fill) {
        canvas.drawPath(
          path,
          Paint()..color = colour.withValues(alpha: 0.35),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..blendMode = BlendMode.plus,
      );
    }

    channel(data.luma, Colors.white70, fill: true);
    channel(data.red, const Color(0xFFE05050));
    channel(data.green, const Color(0xFF50C050));
    channel(data.blue, const Color(0xFF5080E0));

    // Quarter-level gridlines so "middle grey is at the middle" is readable.
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
  }

  /// Crosshair and skin-tone line. The I-line sits where skin of every tone
  /// falls on a vectorscope, which is what makes the instrument useful for
  /// checking a grade has not turned people green.
  void _paintVectorGraticule(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(centre.dx, 0),
      Offset(centre.dx, size.height),
      paint,
    );
    canvas.drawLine(Offset(0, centre.dy), Offset(size.width, centre.dy), paint);
    canvas.drawCircle(centre, size.shortestSide * 0.375, paint);
    canvas.drawCircle(centre, size.shortestSide * 0.1875, paint);

    // Skin-tone line, upper-left quadrant at the conventional ~123°:
    // cos/sin of that angle baked in as ratios. Skin of every tone falls on
    // this line, which is what makes it worth drawing.
    final end = Offset(
      centre.dx - size.shortestSide * 0.45 * 0.55,
      centre.dy - size.shortestSide * 0.45 * 0.83,
    );
    canvas.drawLine(
      centre,
      end,
      Paint()
        ..color = const Color(0x66E0A080)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) =>
      old.kind != kind || old.data != data;
}
