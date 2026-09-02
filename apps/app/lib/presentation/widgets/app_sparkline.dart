import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A shadowless, high-contrast sparkline chart with optional interactive cursor scrubber.
class AppSparkline extends StatefulWidget {
  final List<double> data;
  final double width;
  final double height;
  final Color? color;
  final double strokeWidth;
  final bool isInteractive;
  final ValueChanged<int?>? onHoverIndexChanged;

  const AppSparkline({
    super.key,
    required this.data,
    this.width = 80,
    this.height = 32,
    this.color,
    this.strokeWidth = 1.5,
    this.isInteractive = false,
    this.onHoverIndexChanged,
  });

  @override
  State<AppSparkline> createState() => _AppSparklineState();
}

class _AppSparklineState extends State<AppSparkline> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty || widget.data.length < 2) {
      return SizedBox(width: widget.width, height: widget.height);
    }

    final lineColor = widget.color ?? AppTheme.primary;

    Widget sparklineWidget = CustomPaint(
      size: Size(widget.width, widget.height),
      painter: _SparklinePainter(
        data: widget.data,
        color: lineColor,
        strokeWidth: widget.strokeWidth,
        hoveredIndex: _hoveredIndex,
      ),
    );

    if (!widget.isInteractive) {
      return Semantics(
        label: 'Trend chart showing ${widget.data.length} data points',
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: sparklineWidget,
        ),
      );
    }

    return MouseRegion(
      onHover: (event) {
        final localX = event.localPosition.dx.clamp(0.0, widget.width);
        final ratio = localX / widget.width;
        final index = (ratio * (widget.data.length - 1)).round();
        if (_hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
          widget.onHoverIndexChanged?.call(index);
        }
      },
      onExit: (_) {
        setState(() => _hoveredIndex = null);
        widget.onHoverIndexChanged?.call(null);
      },
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: sparklineWidget,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final double strokeWidth;
  final int? hoveredIndex;

  _SparklinePainter({
    required this.data,
    required this.color,
    required this.strokeWidth,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final min = data.reduce((a, b) => a < b ? a : b);
    final max = data.reduce((a, b) => a > b ? a : b);
    final range = max - min;

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final points = <Offset>[];

    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final normalizedY = range > 0 ? (data[i] - min) / range : 0.5;
      final y = size.height - normalizedY * size.height;
      final pt = Offset(x, y);
      points.add(pt);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, linePaint);

    // Subtle 10% opacity fill underneath (no blurry gradient)
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Scrubber hairline and active dot if hovered
    if (hoveredIndex != null &&
        hoveredIndex! >= 0 &&
        hoveredIndex! < points.length) {
      final activePoint = points[hoveredIndex!];

      // Vertical hairline (1px solid subtle border)
      final hairlinePaint = Paint()
        ..color = AppTheme.borderHighlight
        ..strokeWidth = 1.0;
      canvas.drawLine(
        Offset(activePoint.dx, 0),
        Offset(activePoint.dx, size.height),
        hairlinePaint,
      );

      // Active node dot
      final dotBgPaint = Paint()
        ..color = AppTheme.background
        ..style = PaintingStyle.fill;
      final dotBorderPaint = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(activePoint, 3.5, dotBgPaint);
      canvas.drawCircle(activePoint, 3.5, dotBorderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.data != data ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.hoveredIndex != hoveredIndex;
  }
}
