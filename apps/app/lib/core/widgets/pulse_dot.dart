import 'package:flutter/material.dart';

/// Live status pulse dot — radar ping animation.
/// Expands a faint ring outward every 2s at 0.5 opacity.
class PulseDot extends StatefulWidget {
  final Color color;
  final double size;
  final Duration duration;

  const PulseDot({
    super.key,
    required this.color,
    this.size = 8.0,
    this.duration = const Duration(seconds: 2),
  });

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Semantics(
        label: 'System status indicator',
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
          ),
        ),
      );
    }

    return Semantics(
      label: 'System status indicator',
      child: SizedBox(
        width: widget.size + 8,
        height: widget.size + 8,
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final pulse = _controller.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding ring
                  Container(
                    width: widget.size + (8 * pulse),
                    height: widget.size + (8 * pulse),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.color.withValues(
                          alpha: 0.5 * (1 - pulse),
                        ),
                        width: 1.0,
                      ),
                    ),
                  ),
                  // Solid core dot
                  Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
