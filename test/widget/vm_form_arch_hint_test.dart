import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/ui/providers.dart';
import 'package:vm_machine/ui/screens/vm_form_screen.dart';
import 'package:vm_machine/ui/theme/theme.dart';

import '../fakes/fakes.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> pump(WidgetTester tester, GuestArch arch) async {
    final vm = VmProfile(
      id: 'a',
      name: 'Alpha',
      guestOs: GuestOs.linux,
      guestArch: arch,
      cpuCount: 2,
      memoryMiB: 1024,
      disks: const [DiskRef(path: '/d/a.qcow2', virtualSizeBytes: 1 << 30)],
      media: const [
        MediaRef(
          path: 'content://media/42',
          kind: MediaKind.iso,
          displayName: 'debian-live-13.8.0-amd64-standard.iso',
        ),
      ],
      createdAt: DateTime.utc(2025),
    );
    final repo = MemoryVmRepository();
    await repo.save(vm);
    final fs = FakeFileSystem();
    final controller = VmManagerController(
      repository: repo,
      engine: FakeEngineService(),
      files: fs,
      fileOps: FakeFileOps(fs),
      hostProbe: FakeHostProbe(capabilities: const HostCapabilities()),
      layout: const VmLayout('/docs'),
      pathExists: (_) async => false,
    );
    await controller.load();
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vmManagerControllerProvider.overrideWithValue(controller)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const VmFormScreen(vmId: 'a'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('shows the warning when media arch differs from the VM', (
    t,
  ) async {
    await pump(t, GuestArch.arm64);
    expect(find.textContaining('looks like an x86_64 image'), findsOneWidget);
  });

  testWidgets('shows no warning when architectures match', (t) async {
    await pump(t, GuestArch.x86_64);
    expect(find.textContaining('looks like an'), findsNothing);
  });
}
