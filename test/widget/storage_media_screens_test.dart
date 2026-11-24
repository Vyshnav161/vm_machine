import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/services.dart';
import 'package:vm_machine/ui/providers.dart';
import 'package:vm_machine/ui/screens/compatibility_screen.dart';
import 'package:vm_machine/ui/screens/media_attach_screen.dart';
import 'package:vm_machine/ui/screens/storage_overview_screen.dart';
import 'package:vm_machine/ui/theme/theme.dart';

import '../fakes/fakes.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final vm = VmProfile(
    id: 'a',
    name: 'Alpha',
    guestOs: GuestOs.linux,
    guestArch: GuestArch.x86_64,
    cpuCount: 2,
    memoryMiB: 1024,
    disks: const [DiskRef(path: '/d/a.qcow2', virtualSizeBytes: 1 << 30)],
    media: const [MediaRef(path: '/m/ubuntu.iso', kind: MediaKind.iso)],
    createdAt: DateTime.utc(2025),
  );

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    FakeEngineService? engine,
  }) async {
    final repo = MemoryVmRepository();
    await repo.save(vm);
    final fs = FakeFileSystem();
    final controller = VmManagerController(
      repository: repo,
      engine: engine ?? FakeEngineService(),
      files: fs,
      fileOps: FakeFileOps(fs),
      hostProbe: FakeHostProbe(capabilities: const HostCapabilities()),
      layout: const VmLayout('/docs'),
      pathExists: (_) async => false,
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vmManagerControllerProvider.overrideWithValue(controller),
          fileSizeResolverProvider.overrideWithValue(
            (path) async => path.endsWith('.qcow2') ? 2048 : null,
          ),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: screen),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('storage overview shows virtual, actual and total', (t) async {
    await pump(t, const StorageOverviewScreen());
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('1.0 GB'), findsOneWidget);
    expect(find.text('2.0 KB'), findsWidgets);
  });

  testWidgets('media screen lists attached media and supported formats', (
    t,
  ) async {
    await pump(t, const MediaAttachScreen(vmId: 'a'));
    expect(find.text('ubuntu.iso'), findsOneWidget);
    expect(find.textContaining('.qcow2'), findsOneWidget);
    expect(find.byTooltip('Detach'), findsOneWidget);
  });

  testWidgets('compatibility screen shows engine installed', (t) async {
    await pump(t, const CompatibilityScreen());
    expect(find.text('QEMU engine'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.byKey(const Key('engine-status-help')), findsNothing);
  });

  testWidgets('compatibility screen shows engine not installed', (t) async {
    final engine = FakeEngineService()
      ..engineStatusResult = const EngineStatus.none();
    await pump(t, const CompatibilityScreen(), engine: engine);
    expect(find.text('Not installed'), findsOneWidget);
    expect(find.textContaining('tools/README.md'), findsOneWidget);
  });
}
