import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Fixed dark background with slowly floating color blobs and a faint dot
/// grid, like the portfolio site. Wrap the app (or a screen) with it.
class AppBackground extends StatefulWidget {
  const AppBackground({super.key, required this.child, this.animate = true});

  final Widget child;

  /// Disable the floating animation (tests, reduced motion).
  final bool animate;

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AppBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.animate && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _BlobPainter(Curves.easeInOut.transform(_c.value)),
              ),
            ),
          ),
          const RepaintBoundary(child: CustomPaint(painter: _DotGridPainter())),
          widget.child,
        ],
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.t);
  final double t;

  void _blob(
    Canvas canvas,
    Offset center,
    double diameter,
    Color color,
    double opacity,
  ) {
    final r = diameter / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: opacity),
          color.withValues(alpha: opacity * 0.4),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 0.45, 1],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final a = t * 2 * math.pi;
    // Radial falloff stands in for the site's ~100px blur.
    _blob(
      canvas,
      Offset(0.05 * w + 40 * math.sin(a), 0.1 * h + 50 * t),
      520,
      AppColors.pink,
      0.34,
    );
    _blob(
      canvas,
      Offset(0.95 * w - 50 * t, 0.5 * h + 40 * math.cos(a)),
      480,
      AppColors.blue,
      0.28,
    );
    _blob(
      canvas,
      Offset(0.4 * w + 60 * math.sin(a + 1), 0.95 * h - 40 * t),
      440,
      AppColors.purple,
      0.36,
    );
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.t != t;
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 30.0;
    final paint = Paint();
    for (double y = spacing / 2; y < size.height; y += spacing) {
      final fade = (1 - y / size.height).clamp(0.0, 1.0);
      paint.color = Colors.white.withValues(alpha: 0.07 * fade);
      for (double x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => false;
}
