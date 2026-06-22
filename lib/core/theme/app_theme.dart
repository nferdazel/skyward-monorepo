import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  static const Color info = SkywardColors.darkAccent;
  static const Color neutral = SkywardColors.darkNeutral;

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
      textTheme: GoogleFonts.interTextTheme(
        const TextTheme(
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
          labelLarge: TextStyle(
            fontFamily: 'IBM Plex Mono',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: SkywardColors.darkAccent,
            letterSpacing: 0.08,
          ),
          labelMedium: TextStyle(
            fontFamily: 'IBM Plex Mono',
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.darkTextSec,
            letterSpacing: 0.12,
          ),
          labelSmall: TextStyle(
            fontFamily: 'IBM Plex Mono',
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
        titleTextStyle: GoogleFonts.ibmPlexMono(
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
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexMono(
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
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexMono(
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
          horizontal: 20,
          vertical: 18,
        ),
        labelStyle: GoogleFonts.ibmPlexMono(
          color: SkywardColors.darkTextSec,
          fontSize: 12,
          letterSpacing: 0.08,
        ),
        hintStyle: GoogleFonts.ibmPlexMono(
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

  // ── LIGHT THEME DEFINITION ──
  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: SkywardColors.lightAccent,
      scaffoldBackgroundColor: SkywardColors.lightBg,
      cardColor: SkywardColors.lightSurface,
      dividerColor: SkywardColors.lightBorder,
      colorScheme: const ColorScheme.light(
        primary: SkywardColors.lightAccent,
        secondary: SkywardColors.lightAccentSubtle,
        surface: SkywardColors.lightSurface,
        error: SkywardColors.lightRed,
        onPrimary: Colors.white,
        onSecondary: Colors.black,
        onSurface: SkywardColors.lightTextPri,
      ),
      textTheme: GoogleFonts.ibmPlexSansTextTheme(
        const TextTheme(
          displayLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
          ),
          displayMedium: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
          ),
          displaySmall: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
          ),
          headlineLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
            letterSpacing: 0.5,
          ),
          headlineMedium: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: SkywardColors.lightTextPri,
          ),

          headlineSmall: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: SkywardColors.lightTextPri,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: SkywardColors.lightTextPri,
          ),
          titleSmall: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: SkywardColors.lightTextPri,
          ),

          bodyLarge: TextStyle(
            fontSize: 14,
            color: SkywardColors.lightTextPri,
            height: 1.4,
          ),
          bodyMedium: TextStyle(
            fontSize: 13,
            color: SkywardColors.lightTextSec,
            height: 1.4,
          ),

          bodySmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.lightTextSec,
          ),
          labelLarge: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: SkywardColors.lightAccent,
            letterSpacing: 1.0,
          ),
          labelMedium: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.lightTextSec,
          ),
          labelSmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: SkywardColors.lightTextDim,
            letterSpacing: 1.0,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: SkywardColors.lightSurface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.ibmPlexSans(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: SkywardColors.lightTextPri,
        ),
        iconTheme: const IconThemeData(color: SkywardColors.lightAccent),
        shape: const Border(
          bottom: BorderSide(color: SkywardColors.lightBorder, width: 1.0),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SkywardColors.lightAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexSans(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: 0.1,
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SkywardColors.lightAccent,
          side: const BorderSide(color: SkywardColors.lightAccent, width: 1.0),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: GoogleFonts.ibmPlexSans(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: 0.1,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SkywardColors.lightSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
        labelStyle: GoogleFonts.ibmPlexSans(
          color: SkywardColors.lightTextSec,
          fontSize: 12,
          letterSpacing: 0.1,
        ),
        hintStyle: GoogleFonts.ibmPlexSans(
          color: SkywardColors.lightTextDim,
          fontSize: 12,
          letterSpacing: 0.1,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.lightBorder, width: 1.0),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.lightAccent, width: 1.0),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.lightRed, width: 1.0),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: SkywardColors.lightRed, width: 1.0),
        ),
      ),
    );
  }
}
