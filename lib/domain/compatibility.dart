/// Compatibility evaluation, engine catalog and recommended defaults.
/// Pure Dart only.
library;

import 'enums.dart';
import 'host_capabilities.dart';

const int _gib = 1024 * 1024 * 1024;

/// Warnings attached to a compatibility entry.
enum CompatibilityWarning { reducedPerformance, notRecommendedLowRam }

/// Which (guest OS, guest arch) pairs the bundled engine can run.
abstract final class EngineCatalog {
  /// The first release ships a build for every pair.
  static bool supports(GuestOs os, GuestArch arch) => true;

  /// Why the pair is unsupported, or null when supported.
  static String? blockedReason(GuestOs os, GuestArch arch) => supports(os, arch)
      ? null
      : 'The emulation engine has no build for ${os.name} on ${arch.name}.';
}

class CompatibilityEntry {
  final GuestOs os;
  final GuestArch arch;
  final bool runnable;

  /// Null when not runnable.
  final AccelerationMode? mode;
  final List<CompatibilityWarning> warnings;
  final String? blockedReason;

  const CompatibilityEntry({
    required this.os,
    required this.arch,
    required this.runnable,
    this.mode,
    this.warnings = const [],
    this.blockedReason,
  });

  @override
  bool operator ==(Object other) =>
      other is CompatibilityEntry &&
      other.os == os &&
      other.arch == arch &&
      other.runnable == runnable &&
      other.mode == mode &&
      _listEq(other.warnings, warnings) &&
      other.blockedReason == blockedReason;

  @override
  int get hashCode => Object.hash(
    os,
    arch,
    runnable,
    mode,
    Object.hashAll(warnings),
    blockedReason,
  );

  @override
  String toString() =>
      'CompatibilityEntry($os, $arch, runnable: $runnable, mode: $mode, '
      'warnings: $warnings, blocked: $blockedReason)';
}

class CompatibilityReport {
  final HostCapabilities host;

  /// One entry per (GuestOs, GuestArch).
  final List<CompatibilityEntry> entries;

  const CompatibilityReport({required this.host, required this.entries});

  CompatibilityEntry? entryFor(GuestOs os, GuestArch arch) {
    for (final e in entries) {
      if (e.os == os && e.arch == arch) return e;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CompatibilityReport &&
      other.host == host &&
      _listEq(other.entries, entries);

  @override
  int get hashCode => Object.hash(host, Object.hashAll(entries));
}

abstract final class CompatibilityEvaluator {
  /// RAM below this makes Windows and macOS "not recommended" (Req 1.5).
  static const int lowRamThresholdBytes = 4 * _gib;

  static CompatibilityReport evaluate(HostCapabilities host) {
    final hostArch = host.arch.valueOrNull;
    final ram = host.totalRamBytes.valueOrNull;
    final virtOn = host.hardwareVirtualization.valueOrNull == true;
    final entries = <CompatibilityEntry>[];

    for (final os in GuestOs.values) {
      for (final arch in GuestArch.values) {
        if (!EngineCatalog.supports(os, arch)) {
          entries.add(
            CompatibilityEntry(
              os: os,
              arch: arch,
              runnable: false,
              blockedReason: EngineCatalog.blockedReason(os, arch),
            ),
          );
          continue;
        }
        final mode =
            (arch == GuestArch.arm64 && hostArch == GuestArch.arm64 && virtOn)
            ? AccelerationMode.hardwareVirtualization
            : AccelerationMode.softwareEmulation;
        final warnings = <CompatibilityWarning>[];
        if (arch == GuestArch.x86_64 && hostArch != GuestArch.x86_64) {
          warnings.add(CompatibilityWarning.reducedPerformance);
        }
        if (os != GuestOs.linux && ram != null && ram < lowRamThresholdBytes) {
          warnings.add(CompatibilityWarning.notRecommendedLowRam);
        }
        entries.add(
          CompatibilityEntry(
            os: os,
            arch: arch,
            runnable: true,
            mode: mode,
            warnings: List.unmodifiable(warnings),
          ),
        );
      }
    }
    return CompatibilityReport(host: host, entries: List.unmodifiable(entries));
  }
}

class DefaultResources {
  final int cpuCount;
  final int memoryMiB;
  final int diskBytes;

  const DefaultResources(this.cpuCount, this.memoryMiB, this.diskBytes);

  @override
  bool operator ==(Object other) =>
      other is DefaultResources &&
      other.cpuCount == cpuCount &&
      other.memoryMiB == memoryMiB &&
      other.diskBytes == diskBytes;

  @override
  int get hashCode => Object.hash(cpuCount, memoryMiB, diskBytes);

  @override
  String toString() =>
      'DefaultResources($cpuCount, $memoryMiB MiB, $diskBytes B)';
}

abstract final class RecommendedDefaults {
  static DefaultResources forOs(GuestOs os) => switch (os) {
    GuestOs.linux => const DefaultResources(2, 2048, 16 * _gib),
    GuestOs.windows => const DefaultResources(4, 4096, 64 * _gib),
    GuestOs.macos => const DefaultResources(4, 4096, 64 * _gib),
  };
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
