/// Profile draft validation and start eligibility. Pure Dart only.
library;

import 'compatibility.dart';
import 'enums.dart';
import 'host_capabilities.dart';
import 'vm_profile.dart';

const int _mib = 1024 * 1024;

/// Editable fields of a profile before it has an id (create and edit forms).
class ProfileDraft {
  final String name;
  final GuestOs guestOs;
  final GuestArch guestArch;
  final int cpuCount;
  final int memoryMiB;
  final int diskBytes;
  final List<MediaRef> media;
  final NetworkConfig network;
  final List<SharedFolder> sharedFolders;
  final bool batterySaver;
  final bool licenseAcknowledged;

  const ProfileDraft({
    required this.name,
    required this.guestOs,
    required this.guestArch,
    required this.cpuCount,
    required this.memoryMiB,
    required this.diskBytes,
    this.media = const [],
    this.network = const NetworkConfig(),
    this.sharedFolders = const [],
    this.batterySaver = false,
    this.licenseAcknowledged = false,
  });

  ProfileDraft copyWith({
    String? name,
    GuestOs? guestOs,
    GuestArch? guestArch,
    int? cpuCount,
    int? memoryMiB,
    int? diskBytes,
    List<MediaRef>? media,
    NetworkConfig? network,
    List<SharedFolder>? sharedFolders,
    bool? batterySaver,
    bool? licenseAcknowledged,
  }) => ProfileDraft(
    name: name ?? this.name,
    guestOs: guestOs ?? this.guestOs,
    guestArch: guestArch ?? this.guestArch,
    cpuCount: cpuCount ?? this.cpuCount,
    memoryMiB: memoryMiB ?? this.memoryMiB,
    diskBytes: diskBytes ?? this.diskBytes,
    media: media ?? this.media,
    network: network ?? this.network,
    sharedFolders: sharedFolders ?? this.sharedFolders,
    batterySaver: batterySaver ?? this.batterySaver,
    licenseAcknowledged: licenseAcknowledged ?? this.licenseAcknowledged,
  );
}

enum ValidationField { name, memory, cpu, disk, media, license, port }

class ValidationIssue {
  final ValidationField field;
  final String message;

  /// Maximum or available amount shown to the user. Units: memory in MiB,
  /// cpu in cores, disk in bytes. Null for rules without a limit.
  final num? limit;

  const ValidationIssue({
    required this.field,
    required this.message,
    this.limit,
  });

  @override
  bool operator ==(Object other) =>
      other is ValidationIssue &&
      other.field == field &&
      other.message == message &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(field, message, limit);

  @override
  String toString() => 'ValidationIssue($field, $message, limit: $limit)';
}

abstract final class ProfileValidator {
  static const int minHostPort = 1024;
  static const int maxPort = 65535;

  /// Largest memory (MiB) allowed for [totalRamBytes]: 75 percent, rounded down.
  static int maxMemoryMiB(int totalRamBytes) =>
      (totalRamBytes * 3) ~/ (4 * _mib);

  /// Validates a draft. [existingNames] must exclude the profile being edited.
  /// Rules whose host value is [Unknown] are skipped.
  static List<ValidationIssue> validate({
    required ProfileDraft draft,
    required Iterable<String> existingNames,
    required HostCapabilities host,
  }) {
    final issues = <ValidationIssue>[];

    final trimmed = draft.name.trim();
    if (trimmed.isEmpty) {
      issues.add(
        const ValidationIssue(
          field: ValidationField.name,
          message: 'The VM name must not be empty.',
        ),
      );
    } else {
      final lower = trimmed.toLowerCase();
      if (existingNames.any((n) => n.trim().toLowerCase() == lower)) {
        issues.add(
          ValidationIssue(
            field: ValidationField.name,
            message: 'A VM named "$trimmed" already exists.',
          ),
        );
      }
    }

    final ram = host.totalRamBytes.valueOrNull;
    if (ram != null && draft.memoryMiB * _mib * 4 > ram * 3) {
      final max = maxMemoryMiB(ram);
      issues.add(
        ValidationIssue(
          field: ValidationField.memory,
          message:
              'Memory exceeds 75 percent of device RAM. '
              'Maximum allowed: $max MiB.',
          limit: max,
        ),
      );
    }

    final cores = host.cpuCores.valueOrNull;
    if (cores != null && draft.cpuCount > cores) {
      issues.add(
        ValidationIssue(
          field: ValidationField.cpu,
          message:
              'The virtual CPU count exceeds the number of device cores. '
              'Maximum allowed: $cores.',
          limit: cores,
        ),
      );
    }

    final free = host.freeStorageBytes.valueOrNull;
    if (free != null && draft.diskBytes > free) {
      issues.add(
        ValidationIssue(
          field: ValidationField.disk,
          message:
              'The disk size exceeds free storage. '
              'Available: $free bytes.',
          limit: free,
        ),
      );
    }

    if (draft.media.isEmpty) {
      issues.add(
        const ValidationIssue(
          field: ValidationField.media,
          message: 'Attach at least one installation media file.',
        ),
      );
    }

    if (draft.guestOs == GuestOs.macos && !draft.licenseAcknowledged) {
      issues.add(
        const ValidationIssue(
          field: ValidationField.license,
          message: 'Confirm the Apple licensing notice to save a macOS VM.',
        ),
      );
    }

    for (final f in draft.network.forwards) {
      if (f.hostPort < minHostPort) {
        issues.add(
          ValidationIssue(
            field: ValidationField.port,
            message:
                'Android apps cannot bind ports below 1024 '
                '(host port ${f.hostPort}).',
          ),
        );
      } else if (f.hostPort > maxPort) {
        issues.add(
          ValidationIssue(
            field: ValidationField.port,
            message: 'Host port ${f.hostPort} is above $maxPort.',
          ),
        );
      }
    }

    return issues;
  }
}

sealed class StartDecision {
  const StartDecision();
}

class StartAllowed extends StartDecision {
  const StartAllowed();

  @override
  bool operator ==(Object other) => other is StartAllowed;

  @override
  int get hashCode => (StartAllowed).hashCode;

  @override
  String toString() => 'StartAllowed';
}

class StartBlocked extends StartDecision {
  final String reason;
  const StartBlocked(this.reason);

  @override
  bool operator ==(Object other) =>
      other is StartBlocked && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'StartBlocked($reason)';
}

abstract final class StartEligibility {
  static StartDecision check({
    required VmProfile profile,
    required CompatibilityReport report,
    required List<VmProfile> runningVms,
    required Detected<int> hostRamBytes,
  }) {
    final entry = report.entryFor(profile.guestOs, profile.guestArch);
    if (entry == null || !entry.runnable) {
      final why =
          entry?.blockedReason ??
          'This guest OS and architecture combination is not runnable.';
      return StartBlocked(why.isEmpty ? 'Combination is not runnable.' : why);
    }

    final ram = hostRamBytes.valueOrNull;
    if (ram != null) {
      var totalMiB = profile.memoryMiB;
      for (final vm in runningVms) {
        totalMiB += vm.memoryMiB;
      }
      if (totalMiB * _mib * 4 > ram * 3) {
        return StartBlocked(
          'Starting this VM would use $totalMiB MiB in total, which exceeds '
          '75 percent of device RAM (${ProfileValidator.maxMemoryMiB(ram)} '
          'MiB).',
        );
      }
    }
    return const StartAllowed();
  }
}
