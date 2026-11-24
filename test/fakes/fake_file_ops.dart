import 'dart:typed_data';

import 'package:vm_machine/controller/file_ops.dart';

import 'fake_file_system.dart';

/// [FileOps] over a [FakeFileSystem].
class FakeFileOps implements FileOps {
  FakeFileOps(this.fs);
  final FakeFileSystem fs;

  /// Destination paths for which [copyFile] throws.
  final Set<String> failCopyTo = {};

  @override
  Future<void> deletePath(String path) async => fs.deleteTree(path);

  @override
  Future<void> copyFile(String src, String dest) async {
    if (failCopyTo.contains(dest) || !fs.exists(src)) {
      throw StateError('cannot copy $src to $dest');
    }
    fs.addFile(dest, size: fs.files[src]!, content: fs.contents[src]);
  }

  @override
  Future<void> ensureDir(String path) async {}

  /// Paths for which [writeBytes] throws.
  final Set<String> failWriteTo = {};

  @override
  Future<Uint8List?> readBytes(String path) async => fs.data[path];

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    if (failWriteTo.contains(path)) throw StateError('cannot write $path');
    fs.data[path] = bytes;
    fs.addFile(path, size: bytes.length);
  }
}
