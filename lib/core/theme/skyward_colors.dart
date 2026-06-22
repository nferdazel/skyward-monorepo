import 'package:flutter/material.dart';

/* ═══════════════════════════════════════════════════════
   SKYWARD OPS — Color Token System v5.0
   Aviation Command theme — PFD/ATC-inspired cockpit UI.
   Monochrome base, color encodes operational meaning only.
══════════════════════════════════════════════════════ */

class SkywardColors {
  const SkywardColors._();
  // ── Backgrounds ──
  static const darkBg        = Color(0xFF080B10); // Deep cockpit
  static const darkSurface   = Color(0xFF0F1319); // Panel base
  static const darkSurface2  = Color(0xFF161C25); // Raised panel
  static const darkSurface3  = Color(0xFF1E2633); // Elevated card

  // ── Borders ──
  static const darkBorder    = Color(0x1AFFFFFF); // 10% white
  static const darkBorder2   = Color(0x0DFFFFFF); // 5% white

  // ── Primary: HUD Blue ──
  static const darkAccent       = Color(0xFF5B9EE0); // HUD Blue (PFD-inspired)
  static const darkAccentSubtle = Color(0x1A5B9EE0); // 10% opacity
  static const darkAccentBright = Color(0xFF8DBFF0); // Hover/pressed state
  static const darkAccentGhost  = Color(0x0D5B9EE0); // 5% opacity

  // ── Secondary: ATC Teal ──
  static const darkTeal       = Color(0xFF3AAFA0); // ATC Teal (data visualization)
  static const darkTealSubtle = Color(0x1A3AAFA0); // 10% opacity

  // ── Semantic Colors ──
  static const darkGreen       = Color(0xFF34D07B); // PFD Green (desaturated)
  static const darkGreenSubtle = Color(0x1A34D07B);
  static const darkAmber       = Color(0xFFE6A817); // Cockpit Caution Amber
  static const darkAmberSubtle = Color(0x1AE6A817);
  static const darkRed         = Color(0xFFE05555); // Alert Red (~4.72:1 on surface2)
  static const darkRedSubtle   = Color(0x1AE05555);
  static const darkNeutral     = Color(0xFF758489); // Steel Gray (~4.52:1 — passes AA)

  // ── Text ──
  static const darkTextPri   = Color(0xFFDDE2EA); // Cool white (14.8:1 on bg)
  static const darkTextSec   = Color(0xFF8090A3); // Steel blue-gray (5.7:1)
  static const darkTextDim   = Color(0xFF64748B); // Muted (~4.6:1 — passes AA)

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
