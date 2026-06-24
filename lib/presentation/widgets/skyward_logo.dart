import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Skyward brand logo — matches the favicon design.
/// Aviation radar theme with airplane silhouette.
class SkywardLogo extends StatelessWidget {
  final double size;
  final bool showBackground;

  const SkywardLogo({super.key, this.size = 48, this.showBackground = true});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SkywardLogoPainter(
          showBackground: showBackground,
          primaryColor: AppTheme.primary,
          bgColor: AppTheme.surface,
        ),
      ),
    );
  }
}

class _SkywardLogoPainter extends CustomPainter {
  final bool showBackground;
  final Color primaryColor;
  final Color bgColor;

  _SkywardLogoPainter({
    required this.showBackground,
    required this.primaryColor,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Background
    if (showBackground) {
      final bgPaint = Paint()
        ..color = bgColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Radius.circular(size.width * 0.125),
        ),
        bgPaint,
      );
    }

    // Radar rings
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.015;

    ringPaint.color = primaryColor.withValues(alpha: 0.2);
    canvas.drawCircle(center, radius * 0.8, ringPaint);

    ringPaint.color = primaryColor.withValues(alpha: 0.1);
    canvas.drawCircle(center, radius * 0.6, ringPaint);

    // Airplane silhouette
    final planePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;

    final s = size.width;
    final cx = center.dx;
    final cy = center.dy;

    // Fuselage
    final fuselage = Path()
      ..moveTo(cx, cy - s * 0.35) // nose
      ..lineTo(cx + s * 0.06, cy - s * 0.1) // right fuselage
      ..lineTo(cx + s * 0.06, cy + s * 0.2) // right tail
      ..lineTo(cx + s * 0.12, cy + s * 0.3) // right stabilizer
      ..lineTo(cx + s * 0.06, cy + s * 0.28) // right stabilizer inner
      ..lineTo(cx + s * 0.06, cy + s * 0.35) // tail tip
      ..lineTo(cx, cy + s * 0.25) // tail center
      ..lineTo(cx - s * 0.06, cy + s * 0.35) // left tail tip
      ..lineTo(cx - s * 0.06, cy + s * 0.28) // left stabilizer inner
      ..lineTo(cx - s * 0.12, cy + s * 0.3) // left stabilizer
      ..lineTo(cx - s * 0.06, cy + s * 0.2) // left tail
      ..lineTo(cx - s * 0.06, cy - s * 0.1) // left fuselage
      ..close();
    canvas.drawPath(fuselage, planePaint);

    // Left wing
    final leftWing = Path()
      ..moveTo(cx - s * 0.04, cy - s * 0.05)
      ..lineTo(cx - s * 0.38, cy + s * 0.05)
      ..lineTo(cx - s * 0.38, cy + s * 0.1)
      ..lineTo(cx - s * 0.04, cy + s * 0.05)
      ..close();

    final wingPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawPath(leftWing, wingPaint);

    // Right wing
    final rightWing = Path()
      ..moveTo(cx + s * 0.04, cy - s * 0.05)
      ..lineTo(cx + s * 0.38, cy + s * 0.05)
      ..lineTo(cx + s * 0.38, cy + s * 0.1)
      ..lineTo(cx + s * 0.04, cy + s * 0.05)
      ..close();
    canvas.drawPath(rightWing, wingPaint);

    // Center dot (cockpit)
    final dotPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy - s * 0.08), s * 0.04, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _SkywardLogoPainter oldDelegate) {
    return oldDelegate.primaryColor != primaryColor ||
        oldDelegate.bgColor != bgColor ||
        oldDelegate.showBackground != showBackground;
  }
}
