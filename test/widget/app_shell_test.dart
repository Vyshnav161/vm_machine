import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/main.dart';
import 'package:vm_machine/ui/app_router.dart';
import 'package:vm_machine/ui/providers.dart';
import 'package:vm_machine/ui/theme/theme.dart';

import '../fakes/fakes.dart';

VmProfile _vm(String id, String name) => VmProfile(
  id: id,
  name: name,
  guestOs: GuestOs.linux,
  guestArch: GuestArch.x86_64,
  cpuCount: 2,
  memoryMiB: 1024,
  createdAt: DateTime.utc(2025),
);

VmManagerController _controller(MemoryVmRepository repo) {
  final fs = FakeFileSystem();
  return VmManagerController(
    repository: repo,
    engine: FakeEngineService(),
    files: fs,
    fileOps: FakeFileOps(fs),
    hostProbe: FakeHostProbe(capabilities: const HostCapabilities()),
    layout: const VmLayout('/docs'),
    pathExists: (_) async => false,
  );
}

/// Pumps fixed frames. pumpAndSettle never ends with looping animations.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final repo = MemoryVmRepository();
    await repo.save(_vm('a', 'Alpha'));
    await repo.save(_vm('b', 'Beta'));
    final controller = _controller(repo);
    await controller.load();
    final container = ProviderContainer(
      overrides: [vmManagerControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const VmMachineApp(animateBackground: false),
      ),
    );
    await settle(tester);
    return container;
  }

  testWidgets('shell shows the nav bar and switches tabs', (tester) async {
    await pumpApp(tester);
    expect(find.byType(PillNavBar), findsOneWidget);
    await tester.tap(find.text('Storage'));
    await settle(tester);
    expect(find.text('Total used'), findsOneWidget);
  });

  testWidgets('named routes resolve for every screen', (tester) async {
    await pumpApp(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    for (final name in [
      AppRoutes.compatibility,
      AppRoutes.form,
      AppRoutes.details,
      AppRoutes.console,
      AppRoutes.storage,
      AppRoutes.snapshots,
      AppRoutes.logs,
    ]) {
      nav.pushNamed(name, arguments: 'a');
      await settle(tester);
      nav.pop();
      await settle(tester);
    }
  });

  testWidgets('providers expose library, search and VM state', (tester) async {
    final container = await pumpApp(tester);
    expect(container.read(vmLibraryProvider).length, 2);
    container.read(libraryQueryProvider.notifier).set('alp');
    expect(container.read(filteredLibraryProvider).single.name, 'Alpha');
    expect(container.read(vmStateProvider('a')), VmState.poweredOff);
  });

  testWidgets('design-system components render', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const GlassCard(child: Text('card')),
                const GradientText('Gradient'),
                const PillChip('chip', pulsingDot: true),
                PrimaryButton(
                  label: 'Go',
                  onPressed: () => AppToast.show(context, 'Saved'),
                ),
                const GhostButton(label: 'Cancel', onPressed: null),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('card'), findsOneWidget);
    expect(find.text('Gradient'), findsOneWidget);
  });
}
