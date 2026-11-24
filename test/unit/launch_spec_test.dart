import 'package:glados/glados.dart';
import 'package:vm_machine/domain/domain.dart';

const _paths = VmPaths(
  qmpSocketPath: '/run/qmp.sock',
  vncSocketPath: '/run/vnc.sock',
  logPath: '/logs/vm.log',
  shareDir: '/docs/qemu',
);

VmProfile _profile({
  GuestOs os = GuestOs.linux,
  GuestArch arch = GuestArch.x86_64,
}) => VmProfile(
  id: 'a',
  name: 'n',
  guestOs: os,
  guestArch: arch,
  cpuCount: 3,
  memoryMiB: 2048,
  disks: const [DiskRef(path: '/d.qcow2', virtualSizeBytes: 1)],
  media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
  network: const NetworkConfig(
    forwards: [PortForward(hostPort: 2222, guestPort: 22)],
  ),
  sharedFolders: const [SharedFolder(androidPath: '/sdcard/x', mountTag: 'x')],
  createdAt: DateTime.utc(2025),
);

String _after(List<String> a, String flag) => a[a.indexOf(flag) + 1];

void main() {
  const armHw = HostCapabilities(
    arch: Known(GuestArch.arm64),
    hardwareVirtualization: Known(true),
  );

  test('x86_64 linux guest uses q35, tcg, virtio-net, virtfs and hostfwd', () {
    final s = LaunchSpecBuilder.build(_profile(), armHw, _paths);
    expect(s.executable, 'libqemu-system-x86_64.so');
    expect(_after(s.args, '-machine'), 'q35');
    expect(_after(s.args, '-accel'), 'tcg');
    expect(_after(s.args, '-smp'), '3');
    expect(_after(s.args, '-m'), '2048');
    expect(s.args.where((a) => a == '-drive').length, 2);
    expect(s.args.any((a) => a.contains('hostfwd=tcp::2222-:22')), true);
    expect(s.args.contains('virtio-net-pci,netdev=n0'), true);
    expect(
      s.args.any((a) => a.startsWith('local,path=/sdcard/x,mount_tag=x')),
      true,
    );
    expect(_after(s.args, '-qmp'), 'unix:/run/qmp.sock,server,nowait');
    expect(_after(s.args, '-vnc'), 'unix:/run/vnc.sock');
    expect(_after(s.args, '-serial'), 'file:/logs/vm.log');
    expect(_after(s.args, '-display'), 'none');
  });

  test('arm64 guest on arm64 host with kvm uses virt, kvm and UEFI', () {
    final s = LaunchSpecBuilder.build(
      _profile(arch: GuestArch.arm64),
      armHw,
      _paths,
    );
    expect(_after(s.args, '-machine'), 'virt');
    expect(_after(s.args, '-accel'), 'kvm');
    expect(_after(s.args, '-L'), '/docs/qemu');
    expect(_after(s.args, '-bios'), '/docs/qemu/QEMU_EFI.fd');
  });
  test('x86_64 guest passes -L but no -bios', () {
    final s = LaunchSpecBuilder.build(_profile(), armHw, _paths);
    expect(_after(s.args, '-L'), '/docs/qemu');
    expect(s.args.contains('-bios'), false);
  });

  test('windows guest uses e1000 and smb share, no virtfs', () {
    final s = LaunchSpecBuilder.build(
      _profile(os: GuestOs.windows),
      const HostCapabilities(),
      _paths,
    );
    expect(s.args.contains('e1000,netdev=n0'), true);
    expect(s.args.any((a) => a.contains('smb=/sdcard/x')), true);
    expect(s.args.contains('-virtfs'), false);
    expect(_after(s.args, '-accel'), 'tcg');
  });

  group('ISO media', () {
    test('linux x86_64 and arm64 use one virtio-scsi controller and scsi-cd',
        () {
      for (final arch in GuestArch.values) {
        final s = LaunchSpecBuilder.build(
          _profile(arch: arch),
          const HostCapabilities(),
          _paths,
        );
        expect(
          s.args.where((a) => a == 'virtio-scsi-pci,id=scsi0').length,
          1,
        );
        expect(
          s.args.contains('scsi-cd,drive=media0,bus=scsi0.0,bootindex=0'),
          true,
        );
        expect(s.args.any((a) => a.contains('usb-storage')), false);
        expect(
          s.args.contains(
            'file=/m.iso,format=raw,id=media0,media=cdrom,readonly=on,if=none',
          ),
          true,
        );
      }
    });

    test('windows x86_64 uses ide-cd with bootindex and no virtio-scsi', () {
      final s = LaunchSpecBuilder.build(
        _profile(os: GuestOs.windows),
        const HostCapabilities(),
        _paths,
      );
      expect(s.args.contains('ide-cd,drive=media0,bootindex=0'), true);
      expect(s.args.any((a) => a.startsWith('virtio-scsi')), false);
    });

    test('non-ISO media stay on usb-storage and add no scsi controller', () {
      final p = _profile().copyWith(
        media: const [MediaRef(path: '/m.qcow2', kind: MediaKind.qcow2)],
      );
      final s = LaunchSpecBuilder.build(p, const HostCapabilities(), _paths);
      expect(s.args.contains('usb-storage,drive=media0'), true);
      expect(s.args.any((a) => a.startsWith('virtio-scsi')), false);
    });

    test('two ISOs share one controller with increasing bootindex', () {
      final p = _profile().copyWith(
        media: const [
          MediaRef(path: '/a.iso', kind: MediaKind.iso),
          MediaRef(path: '/b.iso', kind: MediaKind.iso),
        ],
      );
      final s = LaunchSpecBuilder.build(p, const HostCapabilities(), _paths);
      expect(s.args.where((a) => a.startsWith('virtio-scsi')).length, 1);
      expect(s.args.contains('scsi-cd,drive=media1,bus=scsi0.0,bootindex=1'),
          true);
    });
  });

  Glados2(
    any.intInRange(1, 16),
    any.intInRange(256, 65536),
  ).test('smp and m reflect the profile', (cpu, mem) {
    // Feature: android-vm-manager, Property 17: Launch spec reflects the profile
    final p = _profile().copyWith(cpuCount: cpu, memoryMiB: mem);
    final s = LaunchSpecBuilder.build(p, const HostCapabilities(), _paths);
    expect(_after(s.args, '-smp'), '$cpu');
    expect(_after(s.args, '-m'), '$mem');
  });
}
