import 'package:flutter/material.dart';

/* ═══════════════════════════════════════════════════════
   SKYWARD OPS — Color Token System v4.0
   Military-grade command center meets premium fintech.
   Monochrome base, color encodes operational meaning only.
══════════════════════════════════════════════════════ */

class SkywardColors {
  const SkywardColors._();
  // ── Backgrounds ──
  static const darkBg        = Color(0xFF0A0C0F);
  static const darkSurface   = Color(0xFF111318);
  static const darkSurface2  = Color(0xFF181C22);
  static const darkSurface3  = Color(0xFF1E222A);

  // ── Borders ──
  static const darkBorder    = Color(0x1FFFFFFF); // rgba(255,255,255,0.12)
  static const darkBorder2   = Color(0x0FFFFFFF); // rgba(255,255,255,0.06)

  // ── Accent: Operational Colors ──
  static const darkAccent    = Color(0xFF448AFF); // blue - informational / links
  static const darkAccentSubtle = Color(0x1F448AFF); // rgba(68,138,255,0.12)
  static const darkAccentBright = Color(0xFF82B1FF);
  static const darkAccentGhost  = Color(0x0D448AFF); // rgba(68,138,255,0.05)

  static const darkGreen     = Color(0xFF00E676); // nominal / ready
  static const darkGreenSubtle = Color(0x1F00E676); // rgba(0,230,118,0.12)
  static const darkRed       = Color(0xFFFF3D00); // critical / grounded
  static const darkRedSubtle = Color(0x1FFF3D00); // rgba(255,61,0,0.12)
  static const darkAmber     = Color(0xFFFFB300); // caution / warning
  static const darkAmberSubtle = Color(0x1FFFB300); // rgba(255,179,0,0.12)
  static const darkNeutral   = Color(0xFF6B7280);

  // ── Text ──
  static const darkTextPri   = Color(0xFFE8EAF0);
  static const darkTextSec   = Color(0xFF8A919D);
  static const darkTextDim   = Color(0xFF5A6170);

  // Light mode (not actively used, kept for compilation)
  static const lightBg       = Color(0xFFF6F8FA);
  static const lightSurface  = Color(0xFFFFFFFF);
  static const lightSurface2 = Color(0xFFF0F3F7);
  static const lightSurface3 = Color(0xFFE8EDF2);
  static const lightBorder   = Color(0xFFD0D7DE);
  static const lightBorder2  = Color(0xFFAFB8C1);
  static const lightAccent   = Color(0xFF448AFF);
  static const lightAccentSubtle = Color(0xFFDFF0FF);
  static const lightAccentBright = Color(0xFF033D8B);
  static const lightAccentGhost  = Color(0x0D448AFF);
  static const lightTextPri  = Color(0xFF24292F);
  static const lightTextSec  = Color(0xFF57606A);
  static const lightTextDim  = Color(0xFF8C959F);
  static const lightGreen    = Color(0xFF00C853);
  static const lightGreenSubtle = Color(0xFFDAFBE1);
  static const lightRed      = Color(0xFFFF3D00);
  static const lightRedSubtle = Color(0xFFFFEBE9);
  static const lightAmber    = Color(0xFFFFB300);
  static const lightAmberSubtle = Color(0xFFFFF8C5);
  static const lightNeutral  = Color(0xFF6B7280);

  // ── Opacity scale ──
  static const double opacitySubtle = 0.06;
  static const double opacityLight = 0.12;
  static const double opacityMedium = 0.24;
  static const double opacityHeavy = 0.48;
}
