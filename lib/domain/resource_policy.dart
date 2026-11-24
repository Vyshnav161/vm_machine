/// Resource policy, battery saver, and status text. Pure Dart only.
library;

import 'enums.dart';

/// Android thermal status, ordered from coolest to hottest.
enum ThermalStatus {
  none,
  light,
  moderate,
  severe,
  critical,
  emergency,
  shutdown,
}

/// `ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL`.
const int trimMemoryRunningCritical = 15;

/// Free storage below this pauses running VMs (Req 8.6).
const int lowStorageThresholdBytes = 500 * 1000 * 1000;

/// Battery percentage at or below which a notice is raised (Req 7.5).
const int lowBatteryPercent = 15;

/// A VM known to the policy, with its current state.
class RunningVmInfo {
  final String id;
  final VmState state;
  final bool supportsSnapshots;

  const RunningVmInfo({
    required this.id,
    this.state = VmState.running,
    this.supportsSnapshots = false,
  });

  @override
  bool operator ==(Object other) =>
      other is RunningVmInfo &&
      other.id == id &&
      other.state == state &&
      other.supportsSnapshots == supportsSnapshots;

  @override
  int get hashCode => Object.hash(id, state, supportsSnapshots);

  @override
  String toString() => 'RunningVmInfo($id, $state, snap: $supportsSnapshots)';
}

/// Latest host signals. Any field may be null when not reported.
class HostSignals {
  final ThermalStatus? thermal;
  final int? batteryPercent;
  final bool? charging;
  final int? trimMemoryLevel;
  final int? freeStorageBytes;

  /// Host network connectivity; null when not reported (Req 11.4).
  final bool? networkConnected;

  const HostSignals({
    this.thermal,
    this.batteryPercent,
    this.charging,
    this.trimMemoryLevel,
    this.freeStorageBytes,
    this.networkConnected,
  });

  @override
  bool operator ==(Object other) =>
      other is HostSignals &&
      other.thermal == thermal &&
      other.batteryPercent == batteryPercent &&
      other.charging == charging &&
      other.trimMemoryLevel == trimMemoryLevel &&
      other.freeStorageBytes == freeStorageBytes &&
      other.networkConnected == networkConnected;

  @override
  int get hashCode => Object.hash(
    thermal,
    batteryPercent,
    charging,
    trimMemoryLevel,
    freeStorageBytes,
    networkConnected,
  );

  @override
  String toString() =>
      'HostSignals(thermal: $thermal, battery: '
      '$batteryPercent, charging: $charging, trim: $trimMemoryLevel, '
      'storage: $freeStorageBytes, network: $networkConnected)';
}

sealed class PolicyAction {
  const PolicyAction();
}

class PauseVm extends PolicyAction {
  final String id;
  const PauseVm(this.id);

  @override
  bool operator ==(Object other) => other is PauseVm && other.id == id;

  @override
  int get hashCode => Object.hash(PauseVm, id);

  @override
  String toString() => 'PauseVm($id)';
}

class SnapshotVm extends PolicyAction {
  final String id;
  const SnapshotVm(this.id);

  @override
  bool operator ==(Object other) => other is SnapshotVm && other.id == id;

  @override
  int get hashCode => Object.hash(SnapshotVm, id);

  @override
  String toString() => 'SnapshotVm($id)';
}

class NotifyBatteryLow extends PolicyAction {
  const NotifyBatteryLow();

  @override
  bool operator ==(Object other) => other is NotifyBatteryLow;

  @override
  int get hashCode => (NotifyBatteryLow).hashCode;

  @override
  String toString() => 'NotifyBatteryLow';
}

class NotifyThermalPause extends PolicyAction {
  const NotifyThermalPause();

  @override
  bool operator ==(Object other) => other is NotifyThermalPause;

  @override
  int get hashCode => (NotifyThermalPause).hashCode;

  @override
  String toString() => 'NotifyThermalPause';
}

class NotifyLowStorage extends PolicyAction {
  const NotifyLowStorage();

  @override
  bool operator ==(Object other) => other is NotifyLowStorage;

  @override
  int get hashCode => (NotifyLowStorage).hashCode;

  @override
  String toString() => 'NotifyLowStorage';
}

abstract final class ResourcePolicy {
  /// Decides actions for [signals]. Only VMs in [VmState.running] are
  /// targeted. Each VM is paused at most once; snapshots precede pauses.
  static List<PolicyAction> decide(
    HostSignals signals,
    List<RunningVmInfo> vms,
  ) {
    final running = vms
        .where((v) => v.state == VmState.running)
        .toList(growable: false);
    if (running.isEmpty) return const [];

    final thermal = signals.thermal;
    final thermalHit =
        thermal != null && thermal.index >= ThermalStatus.severe.index;

    final battery = signals.batteryPercent;
    final batteryHit =
        battery != null &&
        battery <= lowBatteryPercent &&
        signals.charging == false;

    final trim = signals.trimMemoryLevel;
    final trimHit = trim != null && trim >= trimMemoryRunningCritical;

    final storage = signals.freeStorageBytes;
    final storageHit = storage != null && storage < lowStorageThresholdBytes;

    final snapshots = <PolicyAction>[];
    final pauses = <PolicyAction>[];
    final notices = <PolicyAction>[];

    if (trimHit) {
      for (final vm in running) {
        if (vm.supportsSnapshots) snapshots.add(SnapshotVm(vm.id));
      }
    }
    if (thermalHit || trimHit || storageHit) {
      for (final vm in running) {
        pauses.add(PauseVm(vm.id));
      }
    }
    if (thermalHit) notices.add(const NotifyThermalPause());
    if (batteryHit) notices.add(const NotifyBatteryLow());
    if (storageHit) notices.add(const NotifyLowStorage());

    return [...snapshots, ...pauses, ...notices];
  }
}

abstract final class BatterySaver {
  /// Half the vCPU count when enabled, otherwise the full count (Req 7.7).
  static double effectiveCpuCap(int vcpus, bool enabled) =>
      enabled ? vcpus * 0.5 : vcpus.toDouble();
}

abstract final class CrossArchIndicator {
  /// True iff software emulation runs a guest of a different architecture.
  static bool isActive(
    GuestArch hostArch,
    GuestArch guestArch,
    AccelerationMode mode,
  ) => mode == AccelerationMode.softwareEmulation && hostArch != guestArch;
}

abstract final class NotificationText {
  /// Persistent notification text with VM name and state (Req 7.1).
  static String format(String name, VmState state) => '$name: ${state.name}';
}

abstract final class StatsOverlay {
  /// Overlay text with CPU, memory, and acceleration mode (Req 7.2).
  static String format(double cpuPercent, int memBytes, AccelerationMode mode) {
    final mib = (memBytes / (1024 * 1024)).toStringAsFixed(0);
    final modeText = switch (mode) {
      AccelerationMode.softwareEmulation => 'softwareEmulation',
      AccelerationMode.hardwareVirtualization => 'hardwareVirtualization',
    };
    return 'CPU ${cpuPercent.toStringAsFixed(1)}% | '
        'Memory $mib MiB | Mode $modeText';
  }
}
