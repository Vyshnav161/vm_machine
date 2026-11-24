import 'package:flutter/material.dart';

export 'compatibility_screen.dart';
export 'library_screen.dart' show LibraryScreen;
export 'logs_screen.dart' show LogsScreen;
export 'media_attach_screen.dart' show MediaAttachScreen;
export 'snapshots_screen.dart' show SnapshotsScreen;
export 'storage_overview_screen.dart' show StorageOverviewScreen;
export 'vm_details_screen.dart' show VmDetailsScreen;
export 'vm_form_screen.dart' show VmFormScreen;

import '../theme/theme.dart';

/// Shared scaffold used by all screens, plus the screen exports for the router.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({
    super.key,
    required this.title,
    required this.body,
    this.showBack = true,
    this.bottomPadding = 24,
  });

  final String title;
  final Widget body;
  final bool showBack;

  /// Extra space so content clears the floating nav bar on tab screens.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (showBack)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  Expanded(
                    child: GradientText(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ).riseIn(),
              const SizedBox(height: 16),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
