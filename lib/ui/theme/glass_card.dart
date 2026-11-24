import 'package:flutter/material.dart';

import 'tokens.dart';

/// Glass surface: 145deg white gradient and a 1px line border.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = AppRadii.card,
    this.onTap,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppGradients.glass,
          borderRadius: shape,
          border: Border.all(color: AppColors.line),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
