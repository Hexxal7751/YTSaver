import 'package:flutter/material.dart';

import 'settings.dart';

const kBlue = Color(0xFF3B5BFF);
const kViolet = Color(0xFF7B2FF7);
const kMagenta = Color(0xFFE02BD3);

const brandGradient = LinearGradient(
  colors: [kBlue, kViolet, kMagenta],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final amoled = dark && settings.amoled;
  final scheme = ColorScheme.fromSeed(
    seedColor: Color(settings.accent),
    brightness: b,
  );
  final bg = amoled
      ? Colors.black
      : dark
          ? const Color(0xFF0D0A18)
          : const Color(0xFFF6F4FF);
  final bar = amoled
      ? const Color(0xFF0A0A0A)
      : dark
          ? const Color(0xFF15102A)
          : Colors.white;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}