import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';

class AppTypography {
  // ── Letter-spacing tokens ──
  static const double spacingTight = 0.04;
  static const double spacingNormal = 0.08;
  static const double spacingWide = 0.12;

  static Color get textPrimary => AppTheme.textPrimary;
  static Color get textSecondary => AppTheme.textSecondary;
  static Color get textMuted => AppTheme.textMuted;
  static Color get primaryAccent => AppTheme.primary;

  // ── DISPLAY / SCREEN TITLES (IBM Plex Mono) ──
  static final TextStyle screenTitleLarge = GoogleFonts.ibmPlexMono(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.2,
    letterSpacing: 0.06,
  );

  static final TextStyle screenTitleMedium = GoogleFonts.ibmPlexMono(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.2,
    letterSpacing: 0.06,
  );

  // ── SECTION HEADERS (IBM Plex Mono, ALL CAPS) ──
  static final TextStyle sectionHeaderLarge = GoogleFonts.ibmPlexMono(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: 0.1,
  );

  static final TextStyle sectionHeaderMedium = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: 0.1,
  );

  // ── BODY TEXT (Inter) ──
  static final TextStyle bodyLarge = GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    color: textPrimary,
    height: 1.4,
  );

  static final TextStyle bodyMedium = GoogleFonts.inter(
    fontSize: 13,
    fontWeight: FontWeight.normal,
    color: textSecondary,
    height: 1.4,
  );

  // ── MICRO LABELS (IBM Plex Mono, ALL CAPS) ──
  static final TextStyle microLabel = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    height: 1.2,
    letterSpacing: 0.1,
  );

  // ── CAPTIONS / HINTS (Inter) ──
  static final TextStyle captionRegular = GoogleFonts.inter(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textSecondary,
    height: 1.25,
  );

  static final TextStyle captionLight = GoogleFonts.inter(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textMuted,
    height: 1.25,
  );

  // ── BADGE TEXT (IBM Plex Mono, ALL CAPS) ──
  static final TextStyle badgeText = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: primaryAccent,
    letterSpacing: 0.08,
  );

  // ── BUTTON TEXT (IBM Plex Mono) ──
  static final TextStyle buttonText = GoogleFonts.ibmPlexMono(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: Colors.black,
    letterSpacing: 0.08,
  );

  // ── DATA / MONO STYLES (IBM Plex Mono) ──
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

  static final TextStyle telemetry = GoogleFonts.ibmPlexMono(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  // ── MONO VALUE (IBM Plex Mono, for metric values) ──
  static final TextStyle monoValue = GoogleFonts.ibmPlexMono(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  // ── MONO LABEL (IBM Plex Mono, for compact labels) ──
  static final TextStyle monoLabel = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    letterSpacing: 0.08,
  );

  // ── CONVENIENCE STYLES (avoid copyWith abuse) ──
  static final TextStyle labelSecondary = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: textSecondary,
    letterSpacing: spacingNormal,
  );

  static final TextStyle valuePrimary = GoogleFonts.ibmPlexMono(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static final TextStyle captionMuted = GoogleFonts.inter(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textMuted,
    height: 1.25,
  );
}
