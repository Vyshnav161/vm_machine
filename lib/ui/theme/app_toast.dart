import 'package:flutter/material.dart';

import 'tokens.dart';

/// Pill toast styled like the site's: rgba(20,12,44,.95) with a purple border.
abstract final class AppToast {
  static void show(
    BuildContext context,
    String message, {
    bool error = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          duration: duration,
          content: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.toastFill,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                border: Border.all(
                  color: (error ? AppColors.danger : AppColors.purple)
                      .withValues(alpha: 0.5),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  }
}
