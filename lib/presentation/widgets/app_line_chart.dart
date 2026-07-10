import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A simple line chart using CustomPaint for displaying trends.
class AppLineChart extends StatelessWidget {
  final List<double> data;
  final double width;
  final double height;
  final Color? lineColor;
  final Color? fillColor;
  final bool showDots;

  const AppLineChart({
    super.key,
    required this.data,
    this.width = 200,
    this.height = 80,
    this.lineColor,
    this.fillColor,
    this.showDots = true,
  });

  @override
  Widget build(BuildContext context) {
    if (data.length < 2) {
      return SizedBox(width: width, height: height);
    }

    return Semantics(
      label: 'Line chart showing trend over ${data.length} periods',
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _LineChartPainter(
            data: data,
            lineColor: lineColor ?? AppTheme.primary,
            fillColor: fillColor ?? AppTheme.primary.withValues(alpha: 0.1),
            showDots: showDots,
          ),
        ),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> data;
  final Color lineColor;
  final Color fillColor;
  final bool showDots;

  _LineChartPainter({
    required this.data,
    required this.lineColor,
    required this.fillColor,
    required this.showDots,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final min = data.reduce((a, b) => a < b ? a : b);
    final max = data.reduce((a, b) => a > b ? a : b);
    final range = max - min;
    if (range == 0) return;

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - min) / range) * size.height;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    if (showDots) {
      final dotPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;

      for (int i = 0; i < data.length; i++) {
        final x = (i / (data.length - 1)) * size.width;
        final y = size.height - ((data[i] - min) / range) * size.height;
        canvas.drawCircle(Offset(x, y), 2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.data != data || oldDelegate.lineColor != lineColor;
  }
}
