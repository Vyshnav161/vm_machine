import 'package:flutter/material.dart';

import 'tokens.dart';

/// Text filled with the brand gradient. Defaults to the heading look
/// (weight 800, letter-spacing -0.035em).
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    this.style,
    this.gradient = AppGradients.brand,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;
  final Gradient gradient;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final base =
        style ??
        Theme.of(context).textTheme.headlineMedium ??
        const TextStyle(fontSize: 28);
    final size = base.fontSize ?? 28;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => gradient.createShader(rect),
      child: Text(
        text,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: base.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: size * -0.035,
        ),
      ),
    );
  }
}
