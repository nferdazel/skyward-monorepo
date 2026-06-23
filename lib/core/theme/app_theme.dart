import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../presentation/theme/app_spacing.dart';
import 'skyward_colors.dart';

class AppTheme {
  // ── COLOR TOKENS ──
  static const Color primary = SkywardColors.darkAccent;
  static const Color accentSubtle = SkywardColors.darkAccentSubtle;
  static const Color background = SkywardColors.darkBg;
  static const Color surface = SkywardColors.darkSurface;
  static const Color surfaceRaised = SkywardColors.darkSurface2;
  static const Color surfaceElevated = SkywardColors.darkSurface3;
  static const Color border = SkywardColors.darkBorder;
  static const Color borderSubtle = SkywardColors.darkBorder2;

  // ── SEMANTIC COLORS ──
  static const Color success = SkywardColors.darkGreen;
  static const Color successSubtle = SkywardColors.darkGreenSubtle;
  static const Color error = SkywardColors.darkRed;
  static const Color errorSubtle = SkywardColors.darkRedSubtle;
  static const Color warning = SkywardColors.darkAmber;
  static const Color warningSubtle = SkywardColors.darkAmberSubtle;
  static const Color info = SkywardColors.darkTeal;
  static const Color neutral = SkywardColors.darkNeutral;

  // ── TIER / CONDITION EXTRAS ──
  static const Color tierPlatinum = SkywardColors.darkPlatinum;
  static const Color tierGold = SkywardColors.darkGold;
  static const Color orange = SkywardColors.darkOrange;

  // ── TEXT COLORS ──
  static const Color textPrimary = SkywardColors.darkTextPri;
  static const Color textSecondary = SkywardColors.darkTextSec;
  static const Color textMuted = SkywardColors.darkTextDim;

  // ── ACCENT EXTRAS ──
  static const Color accentBright = SkywardColors.darkAccentBright;
  static const Color accentGhost = SkywardColors.darkAccentGhost;

  // ── SECONDARY: ATC TEAL ──
  static const Color teal = SkywardColors.darkTeal;
  static const Color tealSubtle = SkywardColors.darkTealSubtle;

  // ── GRADIENT FALLBACKS ──
  static Gradient get primaryGradient => const LinearGradient(
    colors: [SkywardColors.darkAccent, SkywardColors.darkAccent],
  );

  static Gradient get surfaceGradient => const LinearGradient(
    colors: [SkywardColors.darkSurface, SkywardColors.darkSurface],
  );
  // ── DARK THEME DEFINITION ──
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: SkywardColors.darkAccent,
      scaffoldBackgroundColor: SkywardColors.darkBg,
      cardColor: SkywardColors.darkSurface,
      dividerColor: SkywardColors.darkBorder,
      colorScheme: const ColorScheme.dark(
        primary: SkywardColors.darkAccent,
        secondary: SkywardColors.darkAccentSubtle,
        surface: SkywardColors.darkSurface,
        error: SkywardColors.darkRed,
        onPrimary: Colors.black,
        onSecondary: Colors.white,
        onSurface: SkywardColors.darkTextPri,
      ),
      textTheme: GoogleFonts.ibmPlexSansTextTheme(
        TextTheme(
          displayLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
          ),
          displayMedium: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
          ),
          displaySmall: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
          ),
          headlineLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
            letterSpacing: 0.5,
          ),
          headlineMedium: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.darkTextPri,
          ),

          headlineSmall: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: SkywardColors.darkTextPri,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: SkywardColors.darkTextPri,
          ),
          titleSmall: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: SkywardColors.darkTextPri,
          ),

          bodyLarge: TextStyle(
            fontSize: 14,
            color: SkywardColors.darkTextPri,
            height: 1.4,
          ),
          bodyMedium: TextStyle(
            fontSize: 13,
            color: SkywardColors.darkTextSec,
            height: 1.4,
          ),

          bodySmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.darkTextSec,
          ),
          labelLarge: GoogleFonts.ibmPlexSans(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: SkywardColors.darkAccent,
            letterSpacing: 0.08,
          ),
          labelMedium: GoogleFonts.ibmPlexSans(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.darkTextSec,
            letterSpacing: 0.12,
          ),
          labelSmall: GoogleFonts.ibmPlexSans(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.darkTextDim,
            letterSpacing: 0.12,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: SkywardColors.darkSurface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.ibmPlexSans(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: SkywardColors.darkTextPri,
          letterSpacing: 0.08,
        ),
        iconTheme: const IconThemeData(color: SkywardColors.darkAccent),
        shape: const Border(
          bottom: BorderSide(color: SkywardColors.darkBorder, width: 1.0),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SkywardColors.darkAccent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: AppSpacing.lg),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexSans(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            letterSpacing: 0.08,
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SkywardColors.darkAccent,
          side: const BorderSide(color: SkywardColors.darkAccent, width: 1.0),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: AppSpacing.lg),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexSans(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            letterSpacing: 0.08,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SkywardColors.darkSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.lg,
        ),
        labelStyle: GoogleFonts.ibmPlexSans(
          color: SkywardColors.darkTextSec,
          fontSize: 12,
          letterSpacing: 0.08,
        ),
        hintStyle: GoogleFonts.ibmPlexSans(
          color: SkywardColors.darkTextDim,
          fontSize: 12,
          letterSpacing: 0.08,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.darkBorder, width: 1.0),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.darkAccent, width: 1.0),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.darkRed, width: 1.0),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.darkRed, width: 1.0),
        ),
      ),
    );
  }
}
