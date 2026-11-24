import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'tokens.dart';

/// Entrance animation from the site: translateY 70 -> 0 plus fade, 1s,
/// cubic-bezier(.2,.8,.2,1). [index] staggers siblings.
class RiseIn extends StatelessWidget {
  const RiseIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) => child.riseIn(index: index);
}

extension RiseInExtension on Widget {
  Widget riseIn({int index = 0}) => animate(delay: AppMotion.stagger * index)
      .fadeIn(duration: AppMotion.rise, curve: AppMotion.curve)
      .moveY(
        begin: 70,
        end: 0,
        duration: AppMotion.rise,
        curve: AppMotion.curve,
      );
}
