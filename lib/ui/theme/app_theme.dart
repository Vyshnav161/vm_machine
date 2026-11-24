import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Material theme built from the site tokens.
abstract final class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.purple,
      onPrimary: AppColors.ink,
      secondary: AppColors.pink,
      onSecondary: AppColors.ink,
      tertiary: AppColors.blue,
      onTertiary: AppColors.ink,
      error: AppColors.danger,
      onError: AppColors.ink,
      surface: AppColors.bg,
      onSurface: AppColors.text,
      onSurfaceVariant: AppColors.muted,
      outline: AppColors.line,
      outlineVariant: AppColors.line,
    );

    final base = ThemeData(brightness: Brightness.dark, colorScheme: scheme);
    final inter = GoogleFonts.interTextTheme(
      base.textTheme,
    ).apply(bodyColor: AppColors.text, displayColor: AppColors.text);

    TextStyle? heading(TextStyle? s) => s?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: (s.fontSize ?? 16) * -0.035,
      color: AppColors.text,
    );

    final textTheme = inter.copyWith(
      displayLarge: heading(inter.displayLarge),
      displayMedium: heading(inter.displayMedium),
      displaySmall: heading(inter.displaySmall),
      headlineLarge: heading(inter.headlineLarge),
      headlineMedium: heading(inter.headlineMedium),
      headlineSmall: heading(inter.headlineSmall),
      titleLarge: heading(inter.titleLarge),
      bodySmall: inter.bodySmall?.copyWith(color: AppColors.muted),
      labelSmall: inter.labelSmall?.copyWith(color: AppColors.muted),
    );

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.input),
      borderSide: BorderSide(color: c, width: w),
    );

    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: AppColors.bg,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      dividerColor: AppColors.line,
      iconTheme: const IconThemeData(color: AppColors.text),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x0DFFFFFF),
        hintStyle: const TextStyle(color: AppColors.muted),
        labelStyle: const TextStyle(color: AppColors.muted),
        floatingLabelStyle: const TextStyle(color: AppColors.purple),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: border(AppColors.line),
        enabledBorder: border(AppColors.line),
        disabledBorder: border(AppColors.line),
        focusedBorder: border(AppColors.purple, 1.5),
        errorBorder: border(AppColors.danger),
        focusedErrorBorder: border(AppColors.danger, 1.5),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF140C2C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF140C2C),
        modalBackgroundColor: Color(0xFF140C2C),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.ink
              : AppColors.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.purple
              : const Color(0x1FFFFFFF),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
