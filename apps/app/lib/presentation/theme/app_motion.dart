import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

/// Centralized motion tokens and Emil Kowalski spring physics curves for Skyward.
class AppMotion {
  const AppMotion._();

  // ── Animation Durations ──
  /// Instant micro-interaction feedback (press, hover, active toggle)
  static const Duration micro = Duration(milliseconds: 120);

  /// Component-level transitions (drawer slide, tab switch, filter pill glide)
  static const Duration regular = Duration(milliseconds: 200);

  /// Layout-level morphs and notification stack transitions
  static const Duration toast = Duration(milliseconds: 300);

  /// Telemetry pulse cycle
  static const Duration radarPulse = Duration(milliseconds: 1400);

  // ── Curves & Spring Physics ──
  /// Standard smooth deceleration curve
  static const Curve springOut = Curves.easeOutCubic;

  /// Snappy deceleration curve (Emil Kowalski style for rapid UI feedback)
  static const Curve springSnappy = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Press interaction curve
  static const Curve pressCurve = Curves.easeInOut;

  // ── Transform Scales ──
  /// Tactile button press depth
  static const double buttonPressScale = 0.98;

  /// Tactile card press depth
  static const double cardPressScale = 0.99;

  /// Icon/chip press depth
  static const double microPressScale = 0.96;

  // ── Spring Simulation Factory ──
  /// Creates a snappy spring simulation with responsive damping and mass.
  static SpringSimulation createSpring({
    double start = 0.0,
    double end = 1.0,
    double velocity = 0.0,
    double damping = 20.0,
    double stiffness = 180.0,
    double mass = 1.0,
  }) {
    return SpringSimulation(
      SpringDescription(
        mass: mass,
        stiffness: stiffness,
        damping: damping,
      ),
      start,
      end,
      velocity,
    );
  }
}
