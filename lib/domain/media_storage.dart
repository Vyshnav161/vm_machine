/// Media and storage logic. Pure Dart only.
library;

import 'enums.dart';
import 'vm_profile.dart';

/// Accepts installation media by file extension (Req 4.4).
class MediaFilter {
  static const List<String> supportedExtensions = [
    '.iso',
    '.img',
    '.qcow2',
    '.vhdx',
  ];

  /// True when the extension of [fileName] is supported, ignoring case.
  static bool accepts(String fileName) => kindOf(fileName) != null;

  /// The [MediaKind] for [fileName], or null when unsupported.
  static MediaKind? kindOf(String fileName) {
    final lower = fileName.toLowerCase();
    for (final kind in MediaKind.values) {
      if (lower.endsWith('.${kind.name}')) return kind;
    }
    return null;
  }

  /// Rejection message listing the supported formats.
  static String rejectionMessage(String fileName) =>
      'Unsupported file "$fileName". Supported formats: '
      '${supportedExtensions.join(', ')}.';
}

/// Result of a storage sufficiency check.
class StorageCheckResult {
  final bool ok;
  final String? message;
  const StorageCheckResult.ok() : ok = true, message = null;
  const StorageCheckResult.insufficient(String this.message) : ok = false;

  @override
  bool operator ==(Object other) =>
      other is StorageCheckResult && other.ok == ok && other.message == message;
  @override
  int get hashCode => Object.hash(ok, message);
}

/// Shared by media copy (Req 4.6) and snapshot creation (Req 9.4).
class StorageCheck {
  static StorageCheckResult hasRoom(int requiredBytes, int availableBytes) {
    if (requiredBytes <= availableBytes) return const StorageCheckResult.ok();
    return StorageCheckResult.insufficient(
      'Not enough free storage: $requiredBytes bytes required, '
      '$availableBytes bytes available.',
    );
  }
}

/// Copy progress as a whole percentage (Req 4.3).
class CopyProgress {
  /// Returns 0..100. A non-positive [total] reports 100 (nothing to copy).
  static int percent(int copied, int total) {
    if (total <= 0) return 100;
    if (copied <= 0) return 0;
    if (copied >= total) return 100;
    return (copied * 100) ~/ total;
  }
}

/// Storage used by one VM.
class VmStorageUsage {
  final int diskBytes;
  final int snapshotBytes;
  final int copiedMediaBytes;
  const VmStorageUsage({
    this.diskBytes = 0,
    this.snapshotBytes = 0,
    this.copiedMediaBytes = 0,
  });

  int get total => diskBytes + snapshotBytes + copiedMediaBytes;
}

/// Storage overview across VMs (Req 8.7).
class StorageOverview {
  static int total(Iterable<VmStorageUsage> entries) =>
      entries.fold(0, (sum, e) => sum + e.total);
}

/// Finds referenced files that no longer exist (Req 4.5, 10.9).
class MediaPreflight {
  /// Paths of disks and media in [profile] for which [exists] is false.
  static List<String> missing(
    VmProfile profile,
    bool Function(String) exists,
  ) => [
    for (final d in profile.disks)
      if (!exists(d.path)) d.path,
    for (final m in profile.media)
      if (!exists(m.path)) m.path,
  ];

  /// Returns [profile] with each disk and media status set from [exists].
  static VmProfile markMissing(
    VmProfile profile,
    bool Function(String) exists,
  ) {
    MediaStatus s(String p) =>
        exists(p) ? MediaStatus.present : MediaStatus.missing;
    return profile.copyWith(
      disks: [for (final d in profile.disks) d.copyWith(status: s(d.path))],
      media: [for (final m in profile.media) m.copyWith(status: s(m.path))],
    );
  }
}

/// Attach and detach change only the profile, never files (Req 4.7).
class MediaAttachment {
  static VmProfile attach(VmProfile profile, MediaRef media) =>
      profile.copyWith(media: [...profile.media, media]);

  /// Removes the last media entry with [path]; no-op when none matches.
  static VmProfile detach(VmProfile profile, String path) {
    final i = profile.media.lastIndexWhere((m) => m.path == path);
    if (i < 0) return profile;
    return profile.copyWith(media: [...profile.media]..removeAt(i));
  }
}
