import 'enums.dart';

/// What the Capability_Detector found on the host. Any field may be [Unknown].
class HostCapabilities {
  final Detected<GuestArch> arch;
  final Detected<int> totalRamBytes;
  final Detected<int> freeStorageBytes;
  final Detected<int> cpuCores;
  final Detected<bool> hardwareVirtualization;

  const HostCapabilities({
    this.arch = const Unknown(),
    this.totalRamBytes = const Unknown(),
    this.freeStorageBytes = const Unknown(),
    this.cpuCores = const Unknown(),
    this.hardwareVirtualization = const Unknown(),
  });

  HostCapabilities copyWith({
    Detected<GuestArch>? arch,
    Detected<int>? totalRamBytes,
    Detected<int>? freeStorageBytes,
    Detected<int>? cpuCores,
    Detected<bool>? hardwareVirtualization,
  }) => HostCapabilities(
    arch: arch ?? this.arch,
    totalRamBytes: totalRamBytes ?? this.totalRamBytes,
    freeStorageBytes: freeStorageBytes ?? this.freeStorageBytes,
    cpuCores: cpuCores ?? this.cpuCores,
    hardwareVirtualization:
        hardwareVirtualization ?? this.hardwareVirtualization,
  );

  @override
  bool operator ==(Object other) =>
      other is HostCapabilities &&
      other.arch == arch &&
      other.totalRamBytes == totalRamBytes &&
      other.freeStorageBytes == freeStorageBytes &&
      other.cpuCores == cpuCores &&
      other.hardwareVirtualization == hardwareVirtualization;

  @override
  int get hashCode => Object.hash(
    arch,
    totalRamBytes,
    freeStorageBytes,
    cpuCores,
    hardwareVirtualization,
  );

  @override
  String toString() =>
      'HostCapabilities(arch: $arch, ram: $totalRamBytes, '
      'storage: $freeStorageBytes, cores: $cpuCores, '
      'virt: $hardwareVirtualization)';
}
