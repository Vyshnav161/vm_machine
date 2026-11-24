import 'package:flutter/material.dart';

import 'tokens.dart';

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onPressed,
    required this.decoration,
    required this.foreground,
    this.icon,
    this.glow = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final BoxDecoration decoration;
  final Color foreground;
  final IconData? icon;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final shape = BorderRadius.circular(AppRadii.pill);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: decoration.copyWith(
          borderRadius: shape,
          boxShadow: glow && enabled
              ? [
                  BoxShadow(
                    color: AppColors.purple.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: foreground),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill with the brand gradient fill and ink text.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => _PillButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    glow: true,
    foreground: AppColors.ink,
    decoration: const BoxDecoration(gradient: AppGradients.brand),
  );
}

/// Pill with a glass fill and a line border.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => _PillButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    foreground: AppColors.text,
    decoration: BoxDecoration(
      gradient: AppGradients.glass,
      border: Border.all(color: AppColors.line),
    ),
  );
}
