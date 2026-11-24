import 'package:path/path.dart' as p;

import '../domain/domain.dart';

/// On-device layout under the app documents directory (design: On-device
/// layout). Pure path math, no I/O.
class VmLayout {
  const VmLayout(this.root);

  /// The app documents directory.
  final String root;

  String vmDir(String id) => p.join(root, 'vms', id);
  String disksDir(String id) => p.join(vmDir(id), 'disks');
  String mediaDir(String id) => p.join(vmDir(id), 'media');
  String snapshotsJson(String id) => p.join(vmDir(id), 'snapshots.json');
  String runDir(String id) => p.join(vmDir(id), 'run');
  String logPath(String id) => p.join(root, 'logs', '$id.log');

  /// QEMU share directory copied from the app assets (`-L`, `QEMU_EFI.fd`).
  String get qemuShareDir => p.join(root, 'qemu');

  String get screenshotsDir => p.join(root, 'screenshots');

  VmPaths pathsFor(String id) => VmPaths(
    qmpSocketPath: p.join(runDir(id), 'qmp.sock'),
    vncSocketPath: p.join(runDir(id), 'vnc.sock'),
    logPath: logPath(id),
    shareDir: qemuShareDir,
  );
}
