import 'package:flutter/material.dart';

import 'screens/placeholder_screens.dart';
import 'theme/theme.dart';

/// Home route: three tabs behind the floating pill navigation bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index = widget.initialIndex;

  static const _items = [
    PillNavItem(Icons.dns_rounded, 'Library'),
    PillNavItem(Icons.memory_rounded, 'Host'),
    PillNavItem(Icons.storage_rounded, 'Storage'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: const [
          LibraryScreen(),
          CompatibilityScreen(tab: true),
          StorageOverviewScreen(tab: true),
        ],
      ),
      bottomNavigationBar: PillNavBar(
        items: _items,
        currentIndex: _index,
        onSelected: (i) => setState(() => _index = i),
      ),
    );
  }
}
