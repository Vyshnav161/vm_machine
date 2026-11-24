import 'package:glados/glados.dart';
import 'package:vm_machine/domain/domain.dart';

VmProfile _profile({int cpu = 2, int mem = 2048}) => VmProfile(
  id: 'a',
  name: 'n',
  guestOs: GuestOs.linux,
  guestArch: GuestArch.arm64,
  cpuCount: cpu,
  memoryMiB: mem,
  disks: [const DiskRef(path: '/d.qcow2', virtualSizeBytes: 1)],
  media: [const MediaRef(path: '/m.iso', kind: MediaKind.iso)],
  network: const NetworkConfig(
    forwards: [PortForward(hostPort: 2222, guestPort: 22)],
  ),
  createdAt: DateTime.utc(2025),
);

void main() {
  group('Detected', () {
    test('Known and Unknown have value equality', () {
      expect(const Known(1), const Known(1));
      expect(const Known(1) == const Known(2), false);
      expect(const Unknown<int>(), const Unknown<int>());
      expect(const Known(1).valueOrNull, 1);
      expect(const Unknown<int>().valueOrNull, null);
    });
  });

  group('VmProfile', () {
    test('equal profiles built separately are equal with same hash', () {
      expect(_profile(), _profile());
      expect(_profile().hashCode, _profile().hashCode);
    });

    test('copyWith changes only the given field', () {
      final p = _profile();
      final q = p.copyWith(name: 'x');
      expect(q.name, 'x');
      expect(q.copyWith(name: 'n'), p);
      expect(p.copyWith(), p);
    });

    test('HostCapabilities copyWith and equality', () {
      const h = HostCapabilities();
      final g = h.copyWith(cpuCores: const Known(8));
      expect(g == h, false);
      expect(g.copyWith(cpuCores: const Unknown()), h);
    });
  });

  Glados2(any.positiveIntOrZero, any.positiveIntOrZero).test(
    // Feature: android-vm-manager, copyWith identity round trip
    'copyWith with own values is identity',
    (cpu, mem) {
      final p = _profile(cpu: cpu, mem: mem);
      expect(p.copyWith(cpuCount: p.cpuCount, memoryMiB: p.memoryMiB), p);
    },
  );
}
