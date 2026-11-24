import 'dart:convert';

import 'package:glados/glados.dart';
import 'package:vm_machine/data/profile_serializer.dart';
import 'package:vm_machine/domain/domain.dart';

final _profile = VmProfile(
  id: 'id-1',
  name: 'Ubuntu',
  guestOs: GuestOs.linux,
  guestArch: GuestArch.arm64,
  cpuCount: 2,
  memoryMiB: 2048,
  disks: const [DiskRef(path: '/d.qcow2', virtualSizeBytes: 1 << 30)],
  media: const [
    MediaRef(
      path: 'content://x',
      kind: MediaKind.iso,
      copiedIntoAppStorage: true,
    ),
  ],
  network: const NetworkConfig(
    forwards: [PortForward(hostPort: 2222, guestPort: 22)],
  ),
  sharedFolders: const [SharedFolder(androidPath: '/s', mountTag: 'tag')],
  createdAt: DateTime.utc(2025, 1, 1),
);

void main() {
  const s = ProfileSerializer();

  test('round trip and deterministic print', () {
    final text = s.print(_profile);
    expect(text, contains('"schemaVersion": 1'));
    expect(text, isNot(contains('status')));
    final r = s.parse(text) as Success;
    expect(r.profile, _profile);
    expect(s.print(r.profile), text);
  });

  test('unsupported version is reported', () {
    final m = jsonDecode(s.print(_profile)) as Map<String, dynamic>;
    m['schemaVersion'] = 2;
    final r = s.parse(jsonEncode(m)) as Failure;
    expect(r.error.unsupportedVersion, 2);
  });

  test('missing and mistyped fields name the field', () {
    final m = jsonDecode(s.print(_profile)) as Map<String, dynamic>;
    m.remove('memoryMiB');
    expect((s.parse(jsonEncode(m)) as Failure).error.field, 'memoryMiB');
    m['memoryMiB'] = 1;
    (m['disks'] as List)[0]['path'] = 5;
    expect((s.parse(jsonEncode(m)) as Failure).error.field, 'disks[0].path');
    expect((s.parse('nope') as Failure).error.message, contains('JSON'));
  });
}
