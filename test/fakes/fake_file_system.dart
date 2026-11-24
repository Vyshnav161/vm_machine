import 'dart:typed_data';

import 'package:vm_machine/services/services.dart';

/// In-memory file system plus [FileService]. Files map path -> bytes
/// (a byte count stands in for content; [contents] holds an optional
/// content token used for "unchanged" assertions).
class FakeFileSystem implements FileService {
  /// path -> size in bytes.
  final Map<String, int> files = {};

  /// path -> content token (e.g. a hash) for disk-unchanged assertions.
  final Map<String, String> contents = {};

  /// path -> real content, for files written or read as bytes.
  final Map<String, Uint8List> data = {};

  int? freeBytes;
  PickedMedia? nextPick;
  List<RemovableVolume> volumes = [];
  final List<String> sharedLogs = [];
  final List<String> openedUrls = [];

  /// Source uri -> size, used by [copyMedia].
  final Map<String, int> uris = {};

  FakeFileSystem({this.freeBytes});

  void addFile(String path, {int size = 0, String? content}) {
    files[path] = size;
    if (content != null) contents[path] = content;
  }

  bool exists(String path) => files.containsKey(path);

  void deleteFile(String path) {
    files.remove(path);
    contents.remove(path);
    data.remove(path);
  }

  /// Removes [dir] and everything below it.
  void deleteTree(String dir) {
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    files.removeWhere((k, _) => k == dir || k.startsWith(prefix));
    contents.removeWhere((k, _) => k == dir || k.startsWith(prefix));
    data.removeWhere((k, _) => k == dir || k.startsWith(prefix));
  }

  /// Snapshot of the whole file system, for before/after comparison.
  Map<String, String> fingerprint() => {
    for (final e in files.entries) e.key: '${e.value}:${contents[e.key]}',
  };

  @override
  Future<PickedMedia?> pickMedia() async => nextPick;

  /// Whether All-files access is granted.
  bool allFilesAccess = true;
  int accessRequests = 0;

  /// uri -> real path. A uri in [uris] without an entry maps to
  /// `/storage/emulated/0/<last segment>`.
  final Map<String, String> realPaths = {};

  @override
  Future<bool> hasAllFilesAccess() async => allFilesAccess;

  @override
  Future<bool> requestAllFilesAccess() async {
    accessRequests++;
    return true;
  }

  @override
  Future<String?> resolveRealPath(String uri) async {
    if (!allFilesAccess) return null;
    final known = realPaths[uri];
    if (known != null) return known;
    if (!uris.containsKey(uri)) return null;
    return '/storage/emulated/0/${uri.split('/').last}';
  }

  @override
  Future<CopyResult> copyMedia(String uri, String dest) async {
    final size = uris[uri];
    if (size == null) {
      return const CopyResult(ok: false, error: 'io', message: 'not found');
    }
    final free = freeBytes;
    if (free != null && size > free) {
      return CopyResult(
        ok: false,
        error: 'no_space',
        required: size,
        available: free,
      );
    }
    files[dest] = size;
    if (free != null) freeBytes = free - size;
    return CopyResult(ok: true, path: dest, bytes: size);
  }

  @override
  Future<void> cancelCopy(String dest) async {}

  @override
  Future<int?> freeSpace(String path) async => freeBytes;

  @override
  Future<List<RemovableVolume>> removableVolumes() async => volumes;

  @override
  Future<bool> shareLogs(String path) async {
    sharedLogs.add(path);
    return files.containsKey(path);
  }

  @override
  Future<bool> openUrl(String url) async {
    if (!url.startsWith('https://')) return false;
    openedUrls.add(url);
    return true;
  }
}
