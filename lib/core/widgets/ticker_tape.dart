import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../presentation/theme/app_spacing.dart';
import '../theme/app_theme.dart';

class TickerTape extends StatefulWidget {
  final List<String> messages;
  final double height;

  const TickerTape({
    super.key,
    this.messages = const ['SYSTEM INITIALIZING...'],
    this.height = 24,
  });

  static final TextStyle _monoStyle = GoogleFonts.ibmPlexMono(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: AppTheme.textMuted,
    letterSpacing: 0.1,
  );

  @override
  State<TickerTape> createState() => _TickerTapeState();
}

class _TickerTapeState extends State<TickerTape>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  String get _tickerText {
    if (widget.messages.isEmpty) return 'SYSTEM INITIALIZING...';
    return widget.messages.join('  •  ');
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 30),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: 1.0, end: -1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tickerText = _tickerText;

    if (MediaQuery.disableAnimationsOf(context)) {
      return Container(
        height: widget.height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.surface,
        ),
        child: Center(
          child: Text(
            tickerText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TickerTape._monoStyle,
          ),
        ),
      );
    }

    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
      ),
      clipBehavior: Clip.hardEdge,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(_animation.value * 800, 0),
            child: child,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              tickerText,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: TickerTape._monoStyle,
            ),
          ),
        ),
      ),
    );
  }
}
