import 'package:flutter_test/flutter_test.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';

import '../fakes/fakes.dart';

void main() {
  test(
    'reconcileStaleRuntime marks VMs that died with the app as Error',
    () async {
      final repo = MemoryVmRepository();
      for (final id in ['a', 'b']) {
        await repo.save(
          VmProfile(
            id: id,
            name: id,
            guestOs: GuestOs.linux,
            guestArch: GuestArch.x86_64,
            cpuCount: 2,
            memoryMiB: 1024,
            disks: [DiskRef(path: '/d/$id.qcow2', virtualSizeBytes: 1)],
            media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
            createdAt: DateTime.utc(2025),
          ),
        );
      }
      final engine = FakeEngineService()..staleDirs = ['/docs/vms/a'];
      final fs = FakeFileSystem();
      final c = VmManagerController(
        repository: repo,
        engine: engine,
        files: fs,
        hostProbe: FakeHostProbe(),
        layout: const VmLayout('/docs'),
        pathExists: (p) async => fs.exists(p),
      );
      await c.load();
      expect(await c.reconcileStaleRuntime(), ['a']);
      expect(c.stateOf('a'), VmState.error);
      expect(c.stateOf('b'), VmState.poweredOff);
      await c.dispose();
    },
  );
}
