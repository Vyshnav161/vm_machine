import 'package:flutter/material.dart';

import 'screens/placeholder_screens.dart';
import 'screens/vm_console_screen.dart';
import 'app_shell.dart';

/// Named routes. Screens that take a VM read it from `arguments` (a String
/// id); the form takes an optional id (null creates a VM).
abstract final class AppRoutes {
  static const home = '/';
  static const compatibility = '/compatibility';
  static const form = '/vm/form';
  static const details = '/vm/details';
  static const console = '/vm/console';
  static const storage = '/storage';
  static const snapshots = '/vm/snapshots';
  static const logs = '/vm/logs';
  static const media = '/vm/media';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final id = settings.arguments is String
        ? settings.arguments as String
        : null;
    final Widget? page = switch (settings.name) {
      home => const AppShell(),
      compatibility => const CompatibilityScreen(),
      form => VmFormScreen(vmId: id),
      details => VmDetailsScreen(vmId: id ?? ''),
      console => VmConsoleScreen(vmId: id ?? ''),
      storage => const StorageOverviewScreen(),
      snapshots => SnapshotsScreen(vmId: id ?? ''),
      logs => LogsScreen(vmId: id ?? ''),
      media => MediaAttachScreen(vmId: id ?? ''),
      _ => null,
    };
    if (page == null) return null;
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }
}
