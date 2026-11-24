import 'package:flutter/material.dart';

/// Design tokens taken from the portfolio site CSS.
abstract final class AppColors {
  static const bg = Color(0xFF09061A);
  static const text = Color(0xFFF6F1FF);
  static const muted = Color(0xFFB3ABD0);

  /// rgba(255,255,255,.11)
  static const line = Color(0x1CFFFFFF);

  static const pink = Color(0xFFFF8FC7); // a1
  static const purple = Color(0xFFA78BFA); // a2
  static const blue = Color(0xFF5CC8FF); // a3

  /// Text on gradient buttons.
  static const ink = Color(0xFF150A30);

  static const danger = Color(0xFFFF6B8B);
  static const success = Color(0xFF6EE7B7);
  static const warning = Color(0xFFFFD27A);

  /// Floating nav bar fill, rgba(14,9,32,.78).
  static const navFill = Color(0xC70E0920);

  /// Toast fill, rgba(20,12,44,.95).
  static const toastFill = Color(0xF2140C2C);
}

abstract final class AppGradients {
  /// 120deg pink -> purple (50%) -> blue.
  static const brand = LinearGradient(
    begin: Alignment(-0.87, -0.5),
    end: Alignment(0.87, 0.5),
    colors: [AppColors.pink, AppColors.purple, AppColors.blue],
    stops: [0, 0.5, 1],
  );

  /// 145deg white 8.5% -> white 2.5%.
  static const glass = LinearGradient(
    begin: Alignment(-0.57, -0.82),
    end: Alignment(0.57, 0.82),
    colors: [Color(0x16FFFFFF), Color(0x06FFFFFF)],
  );
}

abstract final class AppRadii {
  static const double card = 22;
  static const double input = 16;
  static const double pill = 999;
}

abstract final class AppMotion {
  /// cubic-bezier(.2,.8,.2,1)
  static const curve = Cubic(0.2, 0.8, 0.2, 1);
  static const rise = Duration(milliseconds: 1000);
  static const stagger = Duration(milliseconds: 90);
}
