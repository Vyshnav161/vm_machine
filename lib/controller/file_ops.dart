import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Plain file operations the controller needs besides [FileService]
/// (delete, copy, mkdir). Injected so tests run on an in-memory file system.
abstract class FileOps {
  /// Deletes a file or directory tree. A missing path is not an error.
  Future<void> deletePath(String path);

  /// Copies a file, creating parent directories of [dest].
  Future<void> copyFile(String src, String dest);

  /// Creates [path] and its parents.
  Future<void> ensureDir(String path);

  /// File content, or null when the file does not exist.
  Future<Uint8List?> readBytes(String path);

  /// Replaces the file content, creating parent directories. The write is
  /// atomic (temp file, then rename).
  Future<void> writeBytes(String path, Uint8List bytes);
}

class IoFileOps implements FileOps {
  const IoFileOps();

  @override
  Future<void> deletePath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        break;
      default:
        await File(path).delete();
    }
  }

  @override
  Future<void> copyFile(String src, String dest) async {
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(src).copy(dest);
  }

  @override
  Future<void> ensureDir(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    final f = File(path);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}
