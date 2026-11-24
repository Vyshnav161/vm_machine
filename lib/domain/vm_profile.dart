import 'enums.dart';

bool _listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _listHash<T>(List<T> a) => Object.hashAll(a);

class DiskRef {
  final String path;
  final int virtualSizeBytes;
  final String format;
  final MediaStatus status;

  const DiskRef({
    required this.path,
    required this.virtualSizeBytes,
    this.format = 'qcow2',
    this.status = MediaStatus.present,
  });

  DiskRef copyWith({
    String? path,
    int? virtualSizeBytes,
    String? format,
    MediaStatus? status,
  }) => DiskRef(
    path: path ?? this.path,
    virtualSizeBytes: virtualSizeBytes ?? this.virtualSizeBytes,
    format: format ?? this.format,
    status: status ?? this.status,
  );

  @override
  bool operator ==(Object other) =>
      other is DiskRef &&
      other.path == path &&
      other.virtualSizeBytes == virtualSizeBytes &&
      other.format == format &&
      other.status == status;

  @override
  int get hashCode => Object.hash(path, virtualSizeBytes, format, status);

  @override
  String toString() => 'DiskRef($path, $virtualSizeBytes, $format, $status)';
}

class MediaRef {
  final String path;
  final MediaKind kind;
  final bool copiedIntoAppStorage;
  final MediaStatus status;

  /// Human-readable file name. [path] may be a content URI with an opaque id.
  final String? displayName;

  /// The name to show in the UI.
  String get label {
    final n = displayName;
    if (n != null && n.isNotEmpty) return n;
    final decoded = Uri.decodeFull(path);
    final i = decoded.lastIndexOf('/');
    return i < 0 ? decoded : decoded.substring(i + 1);
  }

  const MediaRef({
    required this.path,
    required this.kind,
    this.copiedIntoAppStorage = false,
    this.status = MediaStatus.present,
    this.displayName,
  });

  MediaRef copyWith({
    String? path,
    MediaKind? kind,
    bool? copiedIntoAppStorage,
    MediaStatus? status,
    String? displayName,
  }) => MediaRef(
    displayName: displayName ?? this.displayName,
    path: path ?? this.path,
    kind: kind ?? this.kind,
    copiedIntoAppStorage: copiedIntoAppStorage ?? this.copiedIntoAppStorage,
    status: status ?? this.status,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaRef &&
      other.path == path &&
      other.kind == kind &&
      other.copiedIntoAppStorage == copiedIntoAppStorage &&
      other.status == status &&
      other.displayName == displayName;

  @override
  int get hashCode =>
      Object.hash(path, kind, copiedIntoAppStorage, status, displayName);

  @override
  String toString() =>
      'MediaRef($path, $kind, copied: $copiedIntoAppStorage, '
      '$status)';
}

/// A TCP port forward from a host port to a guest port.
class PortForward {
  final int hostPort;
  final int guestPort;

  const PortForward({required this.hostPort, required this.guestPort});

  PortForward copyWith({int? hostPort, int? guestPort}) => PortForward(
    hostPort: hostPort ?? this.hostPort,
    guestPort: guestPort ?? this.guestPort,
  );

  @override
  bool operator ==(Object other) =>
      other is PortForward &&
      other.hostPort == hostPort &&
      other.guestPort == guestPort;

  @override
  int get hashCode => Object.hash(hostPort, guestPort);

  @override
  String toString() => 'PortForward($hostPort -> $guestPort)';
}

class NetworkConfig {
  final NetworkMode mode;
  final List<PortForward> forwards;

  const NetworkConfig({this.mode = NetworkMode.nat, this.forwards = const []});

  NetworkConfig copyWith({NetworkMode? mode, List<PortForward>? forwards}) =>
      NetworkConfig(
        mode: mode ?? this.mode,
        forwards: forwards ?? this.forwards,
      );

  @override
  bool operator ==(Object other) =>
      other is NetworkConfig &&
      other.mode == mode &&
      _listEq(other.forwards, forwards);

  @override
  int get hashCode => Object.hash(mode, _listHash(forwards));

  @override
  String toString() => 'NetworkConfig($mode, $forwards)';
}

class SharedFolder {
  final String androidPath;
  final String mountTag;

  const SharedFolder({required this.androidPath, required this.mountTag});

  SharedFolder copyWith({String? androidPath, String? mountTag}) =>
      SharedFolder(
        androidPath: androidPath ?? this.androidPath,
        mountTag: mountTag ?? this.mountTag,
      );

  @override
  bool operator ==(Object other) =>
      other is SharedFolder &&
      other.androidPath == androidPath &&
      other.mountTag == mountTag;

  @override
  int get hashCode => Object.hash(androidPath, mountTag);

  @override
  String toString() => 'SharedFolder($androidPath, $mountTag)';
}

class SnapshotInfo {
  final String name;
  final DateTime createdAt;
  final int sizeBytes;

  const SnapshotInfo({
    required this.name,
    required this.createdAt,
    required this.sizeBytes,
  });

  SnapshotInfo copyWith({String? name, DateTime? createdAt, int? sizeBytes}) =>
      SnapshotInfo(
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
        sizeBytes: sizeBytes ?? this.sizeBytes,
      );

  @override
  bool operator ==(Object other) =>
      other is SnapshotInfo &&
      other.name == name &&
      other.createdAt == createdAt &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(name, createdAt, sizeBytes);

  @override
  String toString() => 'SnapshotInfo($name, $createdAt, $sizeBytes)';
}

class VmProfile {
  final String id;
  final String name;
  final GuestOs guestOs;
  final GuestArch guestArch;
  final int cpuCount;
  final int memoryMiB;
  final List<DiskRef> disks;
  final List<MediaRef> media;
  final NetworkConfig network;
  final List<SharedFolder> sharedFolders;
  final bool batterySaver;
  final bool licenseAcknowledged;
  final DateTime createdAt;

  const VmProfile({
    required this.id,
    required this.name,
    required this.guestOs,
    required this.guestArch,
    required this.cpuCount,
    required this.memoryMiB,
    this.disks = const [],
    this.media = const [],
    this.network = const NetworkConfig(),
    this.sharedFolders = const [],
    this.batterySaver = false,
    this.licenseAcknowledged = false,
    required this.createdAt,
  });

  VmProfile copyWith({
    String? id,
    String? name,
    GuestOs? guestOs,
    GuestArch? guestArch,
    int? cpuCount,
    int? memoryMiB,
    List<DiskRef>? disks,
    List<MediaRef>? media,
    NetworkConfig? network,
    List<SharedFolder>? sharedFolders,
    bool? batterySaver,
    bool? licenseAcknowledged,
    DateTime? createdAt,
  }) => VmProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    guestOs: guestOs ?? this.guestOs,
    guestArch: guestArch ?? this.guestArch,
    cpuCount: cpuCount ?? this.cpuCount,
    memoryMiB: memoryMiB ?? this.memoryMiB,
    disks: disks ?? this.disks,
    media: media ?? this.media,
    network: network ?? this.network,
    sharedFolders: sharedFolders ?? this.sharedFolders,
    batterySaver: batterySaver ?? this.batterySaver,
    licenseAcknowledged: licenseAcknowledged ?? this.licenseAcknowledged,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is VmProfile &&
      other.id == id &&
      other.name == name &&
      other.guestOs == guestOs &&
      other.guestArch == guestArch &&
      other.cpuCount == cpuCount &&
      other.memoryMiB == memoryMiB &&
      _listEq(other.disks, disks) &&
      _listEq(other.media, media) &&
      other.network == network &&
      _listEq(other.sharedFolders, sharedFolders) &&
      other.batterySaver == batterySaver &&
      other.licenseAcknowledged == licenseAcknowledged &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    guestOs,
    guestArch,
    cpuCount,
    memoryMiB,
    _listHash(disks),
    _listHash(media),
    network,
    _listHash(sharedFolders),
    batterySaver,
    licenseAcknowledged,
    createdAt,
  );

  @override
  String toString() =>
      'VmProfile($id, $name, $guestOs, $guestArch, '
      'cpu: $cpuCount, mem: $memoryMiB)';
}
