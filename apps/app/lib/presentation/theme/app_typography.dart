import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';

class AppTypography {
  // ── Letter-spacing tokens ──
  static const double spacingNone = 0.0;
  static const double spacingTight = 0.04;
  static const double spacingNormal = 0.08;
  static const double spacingRelaxed = 0.5;
  static const double spacingSection = 0.6;
  static const double spacingWide = 0.12;

  static Color get textPrimary => AppTheme.textPrimary;
  static Color get textSecondary => AppTheme.textSecondary;
  static Color get textMuted => AppTheme.textMuted;
  static Color get primaryAccent => AppTheme.primary;

  // ── DISPLAY / SCREEN TITLES (IBM Plex Sans) ──
  static final TextStyle screenTitleLarge = GoogleFonts.ibmPlexSans(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.2,
    letterSpacing: 0.06,
  );

  static final TextStyle screenTitleMedium = GoogleFonts.ibmPlexSans(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.2,
    letterSpacing: 0.06,
  );

  // ── SECTION HEADERS (IBM Plex Sans, ALL CAPS) ──
  static final TextStyle sectionHeaderLarge = GoogleFonts.ibmPlexSans(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: spacingSection,
  );

  static final TextStyle sectionHeaderMedium = GoogleFonts.ibmPlexSans(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: spacingSection,
  );

  // ── BODY TEXT (IBM Plex Sans — readable prose) ──
  static final TextStyle bodyLarge = GoogleFonts.ibmPlexSans(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    color: textPrimary,
    height: 1.4,
  );

  static final TextStyle bodyMedium = GoogleFonts.ibmPlexSans(
    fontSize: 13,
    fontWeight: FontWeight.normal,
    color: textSecondary,
    height: 1.4,
  );

  // ── MICRO LABELS (IBM Plex Sans, ALL CAPS) ──
  static final TextStyle microLabel = GoogleFonts.ibmPlexSans(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: spacingSection,
  );

  // ── NANO LABELS (IBM Plex Sans, compact badges/chips) ──
  static final TextStyle nanoLabel = GoogleFonts.ibmPlexSans(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    letterSpacing: spacingNormal,
  );

  // ── CAPTIONS / HINTS (IBM Plex Sans) ──
  static final TextStyle captionRegular = GoogleFonts.ibmPlexSans(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textSecondary,
    height: 1.25,
  );

  static final TextStyle captionLight = GoogleFonts.ibmPlexSans(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textMuted,
    height: 1.25,
  );

  // ── BADGE TEXT (IBM Plex Sans, ALL CAPS — labels, status tags) ──
  static final TextStyle badgeText = GoogleFonts.ibmPlexSans(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: primaryAccent,
    letterSpacing: spacingNormal,
  );

  // ── BUTTON TEXT (IBM Plex Sans) ──
  static final TextStyle buttonText = GoogleFonts.ibmPlexSans(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: Colors.black,
    letterSpacing: spacingNormal,
  );

  // ── DATA / MONO STYLES (IBM Plex Mono — numbers only) ──
  static final TextStyle hudValue = GoogleFonts.ibmPlexMono(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static final TextStyle dataEmphasis = GoogleFonts.ibmPlexMono(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: textPrimary,
  );

  static final TextStyle largeKpi = GoogleFonts.ibmPlexMono(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    letterSpacing: -0.02,
  );

  static final TextStyle telemetry = GoogleFonts.ibmPlexSans(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  // ── MONO VALUE (IBM Plex Mono, for numeric metric values) ──
  static final TextStyle monoValue = GoogleFonts.ibmPlexMono(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );
}
