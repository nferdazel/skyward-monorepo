import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/theme/app_theme.dart';
import '../theme/app_typography.dart';

/// A simple line chart using CustomPaint for displaying trends.
class AppLineChart extends StatelessWidget {
  final List<double> data;
  final double width;
  final double height;
  final Color? lineColor;
  final Color? fillColor;
  final bool showDots;

  /// When true, shows min/max value labels on the left edge.
  final bool showMinMaxLabels;

  /// Optional formatter for min/max labels. If null, uses raw values.
  final NumberFormat? yFormat;

  /// Optional height override (default is current 60px).
  /// The net-worth chart will use 120px.
  final double? chartHeight;

  const AppLineChart({
    super.key,
    required this.data,
    this.width = 200,
    this.height = 80,
    this.lineColor,
    this.fillColor,
    this.showDots = true,
    this.showMinMaxLabels = false,
    this.yFormat,
    this.chartHeight,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = chartHeight ?? height;

    if (data.length < 2) {
      return SizedBox(width: width, height: effectiveHeight);
    }

    return Semantics(
      label: 'Line chart showing trend over ${data.length} periods',
      child: SizedBox(
        width: width,
        height: effectiveHeight,
        child: CustomPaint(
          painter: _LineChartPainter(
            data: data,
            lineColor: lineColor ?? AppTheme.primary,
            fillColor: fillColor ?? AppTheme.primary.withValues(alpha: 0.1),
            showDots: showDots,
            showMinMaxLabels: showMinMaxLabels,
            yFormat: yFormat,
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
  final bool showMinMaxLabels;
  final NumberFormat? yFormat;

  static const double _labelAreaWidth = 50;

  _LineChartPainter({
    required this.data,
    required this.lineColor,
    required this.fillColor,
    required this.showDots,
    this.showMinMaxLabels = false,
    this.yFormat,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final min = data.reduce((a, b) => a < b ? a : b);
    final max = data.reduce((a, b) => a > b ? a : b);
    final range = max - min;

    // Reserve left space for labels when enabled.
    final double leftOffset = showMinMaxLabels ? _labelAreaWidth : 0;
    final chartSize = Size(size.width - leftOffset, size.height);

    if (range == 0) {
      // Still draw labels even when flat.
      if (showMinMaxLabels) {
        _drawLabels(canvas, size, min, max);
      }
      return;
    }

    // Draw min/max labels behind the chart area.
    if (showMinMaxLabels) {
      _drawLabels(canvas, size, min, max);
    }

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
      final x = leftOffset + (i / (data.length - 1)) * chartSize.width;
      final y = chartSize.height - ((data[i] - min) / range) * chartSize.height;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, chartSize.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(leftOffset + chartSize.width, chartSize.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    if (showDots) {
      final dotPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;

      for (int i = 0; i < data.length; i++) {
        final x = leftOffset + (i / (data.length - 1)) * chartSize.width;
        final y = chartSize.height - ((data[i] - min) / range) * chartSize.height;
        canvas.drawCircle(Offset(x, y), 2, dotPaint);
      }
    }
  }

  void _drawLabels(Canvas canvas, Size size, double min, double max) {
    final style = AppTypography.captionRegular.copyWith(
      color: AppTheme.textMuted,
    );

    final maxText = yFormat != null ? yFormat!.format(max) : max.toStringAsFixed(0);
    final minText = yFormat != null ? yFormat!.format(min) : min.toStringAsFixed(0);

    _paintText(canvas, maxText, Offset(0, 0), style);
    _paintText(canvas, minText, Offset(0, size.height - style.fontSize! * 1.2), style);
  }

  void _paintText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.data != data ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.showMinMaxLabels != showMinMaxLabels;
  }
}
