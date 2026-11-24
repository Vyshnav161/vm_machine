import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/ui/providers.dart';
import 'package:vm_machine/ui/screens/all_files_access_card.dart';
import 'package:vm_machine/ui/screens/media_attach_screen.dart';
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
    createdAt: DateTime.utc(2025),
  );

  Future<FakeFileSystem> pump(
    WidgetTester tester,
    Widget screen, {
    required bool access,
  }) async {
    final repo = MemoryVmRepository();
    await repo.save(vm);
    final fs = FakeFileSystem()..allFilesAccess = access;
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vmManagerControllerProvider.overrideWithValue(controller)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    return fs;
  }

  testWidgets('card shows granted status without a grant button', (t) async {
    await pump(t, const AllFilesAccessCard(), access: true);
    expect(find.text('All-files access granted'), findsOneWidget);
    expect(find.text('Grant All-files access'), findsNothing);
  });

  testWidgets('card offers the grant action when denied', (t) async {
    final fs = await pump(t, const AllFilesAccessCard(), access: false);
    expect(find.textContaining('All-files access is off'), findsOneWidget);
    await t.tap(find.text('Grant All-files access'));
    await t.pump();
    expect(fs.accessRequests, 1);
  });

  testWidgets('card shows the problem and the copy fallback', (t) async {
    var copied = 0;
    await pump(
      t,
      AllFilesAccessCard(
        problem: 'Cannot open it.',
        onCopyInstead: () => copied++,
      ),
      access: true,
    );
    expect(find.text('Cannot open it.'), findsOneWidget);
    await t.tap(find.text('Copy into app storage instead'));
    expect(copied, 1);
  });

  testWidgets('media screen shows the access card', (t) async {
    await pump(t, const MediaAttachScreen(vmId: 'a'), access: false);
    expect(find.text('Grant All-files access'), findsOneWidget);
  });
}
