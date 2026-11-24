import 'package:glados/glados.dart';
import 'package:vm_machine/domain/domain.dart';

VmProfile _profile() => VmProfile(
  id: 'a',
  name: 'n',
  guestOs: GuestOs.linux,
  guestArch: GuestArch.arm64,
  cpuCount: 2,
  memoryMiB: 2048,
  disks: const [DiskRef(path: '/d.qcow2', virtualSizeBytes: 1)],
  media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
  createdAt: DateTime.utc(2025),
);

void main() {
  group('MediaFilter', () {
    test('accepts supported extensions case-insensitively', () {
      expect(MediaFilter.accepts('a.ISO'), isTrue);
      expect(MediaFilter.accepts('a.Qcow2'), isTrue);
      expect(MediaFilter.accepts('a.vhdx'), isTrue);
      expect(MediaFilter.accepts('a.img'), isTrue);
      expect(MediaFilter.accepts('a.zip'), isFalse);
      expect(MediaFilter.accepts('iso'), isFalse);
    });
    test('rejection message lists formats', () {
      final m = MediaFilter.rejectionMessage('a.zip');
      for (final e in MediaFilter.supportedExtensions) {
        expect(m, contains(e));
      }
    });
  });

  group('StorageCheck / CopyProgress / StorageOverview', () {
    test('hasRoom boundary and message', () {
      expect(StorageCheck.hasRoom(10, 10).ok, isTrue);
      final r = StorageCheck.hasRoom(11, 10);
      expect(r.ok, isFalse);
      expect(r.message, allOf(contains('11'), contains('10')));
    });
    test('percent clamps to 0..100', () {
      expect(CopyProgress.percent(0, 100), 0);
      expect(CopyProgress.percent(50, 100), 50);
      expect(CopyProgress.percent(100, 100), 100);
      expect(CopyProgress.percent(200, 100), 100);
    });
    test('total sums all parts', () {
      expect(
        StorageOverview.total(const [
          VmStorageUsage(diskBytes: 1, snapshotBytes: 2, copiedMediaBytes: 3),
          VmStorageUsage(diskBytes: 4),
        ]),
        10,
      );
    });
  });

  group('MediaPreflight and attachment', () {
    test('missing lists absent paths and marks statuses', () {
      final p = _profile();
      expect(MediaPreflight.missing(p, (x) => x == '/d.qcow2'), ['/m.iso']);
      final marked = MediaPreflight.markMissing(p, (x) => x == '/d.qcow2');
      expect(marked.disks.single.status, MediaStatus.present);
      expect(marked.media.single.status, MediaStatus.missing);
    });
    test('attach then detach restores the profile', () {
      final p = _profile();
      const m = MediaRef(path: '/x.img', kind: MediaKind.img);
      final attached = MediaAttachment.attach(p, m);
      expect(attached.media.length, 2);
      expect(MediaAttachment.detach(attached, '/x.img'), p);
    });
  });
}
