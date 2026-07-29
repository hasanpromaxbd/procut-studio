/// Frosted surfaces and the shared decorative primitives.
///
/// Glassmorphism is used sparingly and only where content sits *over* video:
/// the floating transport bar and the tool sheets. A backdrop blur is a
/// full-screen GPU pass, so applying it decoratively across a scrolling list
/// would cost frames for nothing.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.lg)),
    this.blur = 18,
    this.tintOpacity = 0.72,
    this.showBorder = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final double blur;
  final double tintOpacity;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer.withValues(alpha: tintOpacity),
            borderRadius: borderRadius,
            border: showBorder
                ? Border.all(
                    // A faint light edge is what reads as "glass" rather than
                    // "translucent rectangle".
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.6),
                  )
                : null,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Primary action button with the brand gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.gradient,
    this.expand = false,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Gradient? gradient;
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final theme = Theme.of(context);

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        else if (icon != null)
          Icon(icon, size: 20, color: Colors.white),
        if (busy || icon != null) const SizedBox(width: Spacing.sm),
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.md)),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.md)),
          child: Ink(
            decoration: BoxDecoration(
              gradient: gradient ?? AppColors.brandGradient,
              borderRadius: const BorderRadius.all(Radius.circular(Radii.md)),
            ),
            child: Container(
              height: 52,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact icon action used across the editor chrome.
class ToolIconButton extends StatelessWidget {
  const ToolIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effective = enabled && onPressed != null;

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: effective,
        label: label,
        // `container` makes this its own semantics node rather than an
        // annotation that merges upward — without it the label never reaches
        // the tree. `excludeSemantics` then stops the visible caption being
        // announced a second time.
        container: true,
        excludeSemantics: true,
        child: InkWell(
          onTap: effective ? onPressed : null,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          child: AnimatedContainer(
            duration: Motion.fast,
            width: 56,
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: !effective
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                      : selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: !effective
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                        : selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    AppColors.brandViolet.withValues(alpha: 0.22),
                    AppColors.brandCyan.withValues(alpha: 0.16),
                  ],
                ),
              ),
              child: Icon(icon, size: 40, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: Spacing.xl),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: Spacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, Spacing.lg, 0, Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Bottom sheet shell used by every inspector panel.
class ToolSheet extends StatelessWidget {
  const ToolSheet({
    required this.title,
    required this.child,
    this.actions = const [],
    super.key,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  static Future<T?> show<T>(BuildContext context, {required Widget sheet}) =>
      showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => sheet,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                0,
                Spacing.sm,
                Spacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                  ...actions,
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.lg,
                  Spacing.lg,
                  Spacing.xl,
                ),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Labelled slider with a live value readout.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.formatter,
    this.onReset,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String Function(double value)? formatter;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(
              formatter?.call(value) ?? value.toStringAsFixed(2),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            ?(onReset == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    onPressed: onReset,
                    tooltip: 'Reset',
                    visualDensity: VisualDensity.compact,
                  )),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
