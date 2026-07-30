/// Root widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/l10n/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'presentation/screens/home/home_screen.dart';
import 'presentation/screens/settings/settings_screen.dart';

class ProCutApp extends ConsumerWidget {
  const ProCutApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final localeOverride = ref.watch(localeOverrideProvider);

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // Null follows the device; Material's own widgets (date pickers,
      // tooltips, semantics) localise through the delegates below.
      locale: localeOverride,
      supportedLocales: const [Locale('en'), Locale('bn')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeScreen(),
      builder: (context, child) {
        // Clamp text scaling. An editor's timeline and transport are dense by
        // necessity, and beyond ~1.3× the controls start overlapping. Users who
        // need larger text still get it up to that point.
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: scale > 1.3 ? 1.3 : 1.0,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
