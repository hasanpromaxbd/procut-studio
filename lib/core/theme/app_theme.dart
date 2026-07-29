/// Material 3 themes for ProCut Studio.
///
/// Both schemes are hand-built rather than generated from a seed: an editor
/// shows the user's own footage, so surrounding chrome must be predictable and
/// low-chroma. A seeded scheme tints neutrals toward the seed hue, which
/// subtly shifts how graded footage reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'app_dimens.dart';

abstract final class AppTheme {
  static ThemeData dark() => _build(_darkScheme, Brightness.dark);
  static ThemeData light() => _build(_lightScheme, Brightness.light);

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.brandViolet,
    onPrimary: Color(0xFF0A0B10),
    primaryContainer: AppColors.brandIndigo,
    onPrimaryContainer: Color(0xFFEDEAFF),
    secondary: AppColors.brandCyan,
    onSecondary: Color(0xFF00201B),
    secondaryContainer: Color(0xFF00584A),
    onSecondaryContainer: Color(0xFFB8FFF0),
    tertiary: AppColors.brandRose,
    onTertiary: Color(0xFF3B0011),
    tertiaryContainer: Color(0xFF7A0026),
    onTertiaryContainer: Color(0xFFFFD9DF),
    error: AppColors.danger,
    onError: Color(0xFF3B0011),
    errorContainer: Color(0xFF7A0026),
    onErrorContainer: Color(0xFFFFD9DF),
    surface: AppColors.inkBackground,
    onSurface: AppColors.inkTextPrimary,
    surfaceContainerLowest: Color(0xFF07080C),
    surfaceContainerLow: AppColors.inkSurface,
    surfaceContainer: AppColors.inkSurfaceHigh,
    surfaceContainerHigh: AppColors.inkSurfaceHigher,
    surfaceContainerHighest: Color(0xFF2B3040),
    onSurfaceVariant: AppColors.inkTextSecondary,
    outline: AppColors.inkOutline,
    outlineVariant: Color(0xFF232733),
    inverseSurface: Color(0xFFE6E9F2),
    onInverseSurface: Color(0xFF16181F),
    inversePrimary: AppColors.brandIndigo,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.brandIndigo,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFE6E1FF),
    onPrimaryContainer: Color(0xFF1B0B66),
    secondary: Color(0xFF00806B),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFB8FFF0),
    onSecondaryContainer: Color(0xFF00201B),
    tertiary: Color(0xFFB3123C),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFFFD9DF),
    onTertiaryContainer: Color(0xFF3B0011),
    error: Color(0xFFB3123C),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFD9DF),
    onErrorContainer: Color(0xFF3B0011),
    surface: AppColors.paperBackground,
    onSurface: AppColors.paperTextPrimary,
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: AppColors.paperSurface,
    surfaceContainer: AppColors.paperSurfaceHigh,
    surfaceContainerHigh: Color(0xFFE9ECF5),
    surfaceContainerHighest: Color(0xFFE1E5F0),
    onSurfaceVariant: AppColors.paperTextSecondary,
    outline: AppColors.paperOutline,
    outlineVariant: Color(0xFFE4E8F1),
    inverseSurface: Color(0xFF16181F),
    onInverseSurface: Color(0xFFF2F4F8),
    inversePrimary: AppColors.brandViolet,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  static ThemeData _build(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    // Inter for UI chrome; JetBrains Mono for timecode so digits do not jitter
    // as the playhead runs — a proportional font makes the counter shimmer.
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return base.copyWith(
      textTheme: textTheme.copyWith(
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.cardRadius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          side: BorderSide(color: scheme.outline),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetRadius),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: scheme.primary,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        labelStyle: textTheme.labelMedium,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: textTheme.bodyMedium,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.xs)),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant,
        circularTrackColor: scheme.outlineVariant,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// Tabular-figure monospace style for timecode readouts.
  static TextStyle timecode(BuildContext context, {double size = 13}) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: Theme.of(context).colorScheme.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  const AppTheme._();
}
