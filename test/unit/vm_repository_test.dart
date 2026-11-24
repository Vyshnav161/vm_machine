import 'dart:io';

import 'package:glados/glados.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';

VmProfile _p(String id, String name, {int day = 1}) => VmProfile(
  id: id,
  name: name,
  guestOs: GuestOs.linux,
  guestArch: GuestArch.arm64,
  cpuCount: 2,
  memoryMiB: 2048,
  disks: const [DiskRef(path: '/d.qcow2', virtualSizeBytes: 1 << 30)],
  createdAt: DateTime.utc(2025, 1, day),
);

void main() {
  group('FileVmRepository', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vmrepo'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('save, reload with new instance, delete', () async {
      final a = _p('a', 'A', day: 1);
      final b = _p('b', 'B', day: 2);
      final repo = FileVmRepository(tmp);
      await repo.save(b);
      await repo.save(a);
      expect(await FileVmRepository(tmp).loadAll(), [a, b]);
      expect(File('${tmp.path}/vms/a/profile.json').existsSync(), isTrue);
      expect(File('${tmp.path}/vms/a/profile.json.tmp').existsSync(), isFalse);
      await repo.delete('a');
      expect(await repo.loadAll(), [b]);
    });

    test('skips corrupt profile files', () async {
      final repo = FileVmRepository(tmp);
      await repo.save(_p('a', 'A'));
      Directory('${tmp.path}/vms/bad').createSync(recursive: true);
      File('${tmp.path}/vms/bad/profile.json').writeAsStringSync('{nope');
      expect((await repo.loadAll()).map((e) => e.id), ['a']);
    });
  });

  test('MemoryVmRepository save/overwrite/delete', () async {
    final repo = MemoryVmRepository();
    await repo.save(_p('a', 'A'));
    await repo.save(_p('a', 'A2'));
    expect((await repo.loadAll()).single.name, 'A2');
    await repo.delete('a');
    expect(await repo.loadAll(), isEmpty);
  });

  test('CloneNamer sequence', () {
    expect(CloneNamer.uniqueName('X', ['X']), 'X copy');
    expect(CloneNamer.uniqueName('X', ['X', 'X copy']), 'X copy 2');
    expect(CloneNamer.uniqueName('X', ['X', 'x COPY', 'X copy 2']), 'X copy 3');
  });

  test('LibrarySearch', () {
    final ps = [_p('1', 'Ubuntu'), _p('2', 'Debian')];
    expect(LibrarySearch.filter(ps, ''), ps);
    expect(LibrarySearch.filter(ps, 'UBU'), [ps[0]]);
    expect(LibrarySearch.filter(ps, 'zzz'), isEmpty);
  });

  test('import assigns fresh id only on collision', () {
    final p = _p('a', 'A');
    expect(ProfileImport.withFreshIdIfTaken(p, ['b'], () => 'n'), p);
    expect(ProfileImport.withFreshIdIfTaken(p, ['a'], () => 'n').id, 'n');
  });

  // Feature: android-vm-manager, Property 28: Library search
  Glados2(any.list(any.letterOrDigits), any.letterOrDigits).test(
    'search matches lower-cased contains',
    (names, query) {
      final ps = [for (var i = 0; i < names.length; i++) _p('$i', names[i])];
      final got = LibrarySearch.filter(ps, query);
      final want = [
        for (final x in ps)
          if (x.name.toLowerCase().contains(query.toLowerCase())) x,
      ];
      expect(got, want);
      expect(LibrarySearch.filter(ps, ''), ps);
    },
  );

  // Feature: android-vm-manager, Property 29: Clone
  Glados2(any.list(any.letterOrDigits), any.letterOrDigits).test(
    'clone name differs from all existing names',
    (existing, name) {
      final u = CloneNamer.uniqueName(name, existing);
      expect(
        existing.map((e) => e.toLowerCase()),
        isNot(contains(u.toLowerCase())),
      );
      expect(u, startsWith('$name copy'));
    },
  );
}
