import 'enums.dart';
import 'host_capabilities.dart';
import 'vm_profile.dart';

/// Per-VM filesystem locations the builder needs. Pure data (Req 5.1, 12.2).
class VmPaths {
  final String qmpSocketPath;
  final String vncSocketPath;
  final String logPath;

  /// QEMU share directory (BIOS, ROMs, keymaps, `QEMU_EFI.fd`); passed as `-L`.
  final String shareDir;

  const VmPaths({
    required this.qmpSocketPath,
    required this.vncSocketPath,
    required this.logPath,
    required this.shareDir,
  });

  /// UEFI firmware image used for ARM64 guests (`-bios`).
  String get uefiFirmwarePath => '$shareDir/QEMU_EFI.fd';

  @override
  bool operator ==(Object other) =>
      other is VmPaths &&
      other.qmpSocketPath == qmpSocketPath &&
      other.vncSocketPath == vncSocketPath &&
      other.logPath == logPath &&
      other.shareDir == shareDir;

  @override
  int get hashCode =>
      Object.hash(qmpSocketPath, vncSocketPath, logPath, shareDir);
}

/// Everything the engine needs to spawn QEMU for one VM.
class LaunchSpec {
  /// Native library file name, e.g. `libqemu-system-x86_64.so`.
  final String executable;
  final List<String> args;
  final String qmpSocketPath;
  final String vncSocketPath;
  final String logPath;

  const LaunchSpec({
    required this.executable,
    required this.args,
    required this.qmpSocketPath,
    required this.vncSocketPath,
    required this.logPath,
  });

  @override
  bool operator ==(Object other) =>
      other is LaunchSpec &&
      other.executable == executable &&
      _listEq(other.args, args) &&
      other.qmpSocketPath == qmpSocketPath &&
      other.vncSocketPath == vncSocketPath &&
      other.logPath == logPath;

  @override
  int get hashCode => Object.hash(
    executable,
    Object.hashAll(args),
    qmpSocketPath,
    vncSocketPath,
    logPath,
  );

  @override
  String toString() => 'LaunchSpec($executable ${args.join(' ')})';
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Builds the QEMU command line from a profile (Req 5.1, 11.1, 11.2, 11.5).
abstract final class LaunchSpecBuilder {
  /// Hardware virtualization only for an ARM64 guest on a known ARM64 host
  /// that reports `Known(true)`; everything else is software emulation.
  static AccelerationMode accelerationFor(VmProfile p, HostCapabilities host) {
    final hostArm = host.arch.valueOrNull == GuestArch.arm64;
    final hw = host.hardwareVirtualization.valueOrNull == true;
    return p.guestArch == GuestArch.arm64 && hostArm && hw
        ? AccelerationMode.hardwareVirtualization
        : AccelerationMode.softwareEmulation;
  }

  static String executableFor(GuestArch arch) => switch (arch) {
    GuestArch.arm64 => 'libqemu-system-aarch64.so',
    GuestArch.x86_64 => 'libqemu-system-x86_64.so',
  };

  /// Escapes a value for a QEMU comma-separated option (`,` becomes `,,`).
  static String _esc(String v) => v.replaceAll(',', ',,');

  static String _mediaFormat(MediaKind k) => switch (k) {
    MediaKind.iso => 'raw',
    MediaKind.img => 'raw',
    MediaKind.qcow2 => 'qcow2',
    MediaKind.vhdx => 'vhdx',
  };

  static LaunchSpec build(VmProfile p, HostCapabilities host, VmPaths paths) {
    final mode = accelerationFor(p, host);
    final kvm = mode == AccelerationMode.hardwareVirtualization;
    final arm = p.guestArch == GuestArch.arm64;
    final args = <String>['-L', paths.shareDir];

    args.addAll(['-machine', arm ? 'virt' : 'q35']);
    args.addAll(['-accel', kvm ? 'kvm' : 'tcg']);
    args.addAll(['-cpu', kvm ? 'host' : 'max']);
    if (arm) args.addAll(['-bios', paths.uefiFirmwarePath]);
    args.addAll(['-smp', '${p.cpuCount}']);
    args.addAll(['-m', '${p.memoryMiB}']);

    // Display and input devices.
    args.addAll(arm ? ['-device', 'virtio-gpu-pci'] : ['-vga', 'std']);
    args.addAll(['-device', 'qemu-xhci']);
    args.addAll(['-device', 'usb-tablet']);
    args.addAll(['-device', 'usb-kbd']);

    for (var i = 0; i < p.disks.length; i++) {
      final d = p.disks[i];
      args.addAll([
        '-drive',
        'file=${_esc(d.path)},format=${d.format},if=virtio,id=disk$i',
      ]);
    }
    // Windows x86_64 installers lack virtio drivers, so their ISOs use the
    // q35 AHCI bus (ide-cd); every other guest uses virtio-scsi.
    final useIdeCd = p.guestOs == GuestOs.windows && !arm;
    if (!useIdeCd && p.media.any((m) => m.kind == MediaKind.iso)) {
      args.addAll(['-device', 'virtio-scsi-pci,id=scsi0']);
    }
    var isoIndex = 0;
    for (var i = 0; i < p.media.length; i++) {
      final m = p.media[i];
      final fmt = _mediaFormat(m.kind);
      final base = 'file=${_esc(m.path)},format=$fmt,id=media$i';
      if (m.kind == MediaKind.iso) {
        // Boot order: CDs come before the (empty) disk.
        final boot = 'bootindex=${isoIndex++}';
        args.addAll([
          '-drive',
          '$base,media=cdrom,readonly=on,if=none',
          '-device',
          useIdeCd
              ? 'ide-cd,drive=media$i,$boot'
              : 'scsi-cd,drive=media$i,bus=scsi0.0,$boot',
        ]);
      } else {
        args.addAll(['-drive', '$base,if=none']);
        args.addAll(['-device', 'usb-storage,drive=media$i']);
      }
    }

    // User-mode networking with TCP port forwards (Req 11.1, 11.2).
    final netdev = StringBuffer('user,id=n0');
    for (final f in p.network.forwards) {
      netdev.write(',hostfwd=tcp::${f.hostPort}-:${f.guestPort}');
    }
    final nic = p.guestOs == GuestOs.linux ? 'virtio-net-pci' : 'e1000';
    // Windows and macOS use SMB via user networking; QEMU supports one
    // `smb=` directory, so the first shared folder is exported (Req 11.5).
    if (p.guestOs != GuestOs.linux && p.sharedFolders.isNotEmpty) {
      netdev.write(',smb=${_esc(p.sharedFolders.first.androidPath)}');
    }
    args.addAll(['-netdev', netdev.toString()]);
    args.addAll(['-device', '$nic,netdev=n0']);

    if (p.guestOs == GuestOs.linux) {
      for (var i = 0; i < p.sharedFolders.length; i++) {
        final s = p.sharedFolders[i];
        args.addAll([
          '-virtfs',
          'local,path=${_esc(s.androidPath)},mount_tag=${_esc(s.mountTag)},'
              'security_model=none,id=share$i',
        ]);
      }
    }

    args.addAll(['-qmp', 'unix:${_esc(paths.qmpSocketPath)},server,nowait']);
    args.addAll(['-vnc', 'unix:${_esc(paths.vncSocketPath)}']);
    args.addAll(['-serial', 'file:${paths.logPath}']);
    args.addAll(['-display', 'none']);

    return LaunchSpec(
      executable: executableFor(p.guestArch),
      args: List.unmodifiable(args),
      qmpSocketPath: paths.qmpSocketPath,
      vncSocketPath: paths.vncSocketPath,
      logPath: paths.logPath,
    );
  }
}
