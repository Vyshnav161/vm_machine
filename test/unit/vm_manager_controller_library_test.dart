import 'package:flutter_test/flutter_test.dart'
    hide expect, test, group, setUp, expectLater;
import 'package:flutter/services.dart' show PlatformException;
import 'package:glados/glados.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/services.dart';

import '../fakes/fakes.dart';

const _gib = 1024 * 1024 * 1024;

const _host = HostCapabilities(
  arch: Known(GuestArch.arm64),
  totalRamBytes: Known(8 * _gib),
  freeStorageBytes: Known(100 * _gib),
  cpuCores: Known(8),
  hardwareVirtualization: Known(false),
);

VmProfile _profile(
  String id, {
  String name = 'vm',
  List<MediaRef> media = const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
  List<SharedFolder> shares = const [],
}) => VmProfile(
  id: id,
  name: name,
  guestOs: GuestOs.linux,
  guestArch: GuestArch.x86_64,
  cpuCount: 2,
  memoryMiB: 1024,
  disks: [
    DiskRef(path: '/docs/vms/$id/disks/disk0.qcow2', virtualSizeBytes: 1),
  ],
  media: media,
  sharedFolders: shares,
  createdAt: DateTime.utc(2025),
);

ProfileDraft _draft({String name = 'new vm', int memoryMiB = 1024}) =>
    ProfileDraft(
      name: name,
      guestOs: GuestOs.linux,
      guestArch: GuestArch.arm64,
      cpuCount: 2,
      memoryMiB: memoryMiB,
      diskBytes: 4 * _gib,
      media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
    );

class _Env {
  _Env(List<VmProfile> profiles) {
    fs.addFile('/m.iso', size: 5);
    for (final p in profiles) {
      fs.addFile(p.disks.first.path, size: 10, content: 'disk-${p.id}');
      repo.save(p);
    }
    var n = 0;
    c = VmManagerController(
      repository: repo,
      engine: engine,
      files: fs,
      hostProbe: FakeHostProbe(capabilities: _host),
      layout: const VmLayout('/docs'),
      pathExists: (p) async => fs.exists(p),
      fileOps: FakeFileOps(fs),
      newId: () => 'id${++n}',
      now: () => DateTime.utc(2030),
    );
  }

  final repo = MemoryVmRepository();
  final engine = FakeEngineService();
  final fs = FakeFileSystem(freeBytes: 100 * _gib);
  late final VmManagerController c;
}

Future<_Env> _env([List<VmProfile>? profiles]) async {
  final e = _Env(profiles ?? [_profile('a')]);
  await e.c.load();
  return e;
}

void main() {
  group('engine missing', () {
    test('create maps engine_missing to the friendly failure', () async {
      final e = await _env([]);
      e.engine.engineStatusResult = const EngineStatus.none();
      e.engine.failOn('createDisk', code: 'engine_missing');
      final r = await e.c.create(_draft());
      expect(r.ok, isFalse);
      expect(r.failure!.isEngineMissing, isTrue);
      expect(r.message, contains('QEMU engine not installed'));
      expect(r.message, contains('tools/README.md'));
      expect(r.message, contains('tools/build-qemu-android.sh'));
      expect(r.message, contains('libqemu-img.so'));
      expect(r.message, isNot(contains('not executable')));
      expect(e.c.profiles, isEmpty);
    });

    test('start maps engine_missing and records the failure', () async {
      final e = await _env();
      e.engine.engineStatusResult = const EngineStatus({});
      e.engine.failOn('start', code: 'engine_missing');
      final r = await e.c.start('a');
      expect(r.ok, isFalse);
      expect(r.failure!.isEngineMissing, isTrue);
      expect(r.message, contains('QEMU engine not installed'));
      expect(e.c.runtimeOf('a').failureMessage, r.message);
    });

    test('engineStatus reports installed, partial and missing', () async {
      final e = await _env([]);
      expect((await e.c.engineStatus()).installed, isTrue);
      e.engine.engineStatusResult = const EngineStatus({
        EngineStatus.qemuImgLib: true,
        EngineStatus.x86_64Lib: true,
      });
      expect((await e.c.engineStatus()).installed, isTrue);
      e.engine.engineStatusResult = const EngineStatus({
        EngineStatus.qemuImgLib: true,
      });
      final partial = await e.c.engineStatus();
      expect(partial.installed, isFalse);
      expect(partial.partial, isTrue);
      expect(partial.missing, [
        EngineStatus.aarch64Lib,
        EngineStatus.x86_64Lib,
      ]);
      e.engine.engineStatusResult = const EngineStatus({});
      final none = await e.c.engineStatus();
      expect(none.installed, isFalse);
      expect(none.partial, isFalse);
      expect(none.missing.length, 3);
    });

    test('engineStatus reports none when the check fails', () async {
      final e = await _env([]);
      e.engine.failOn('engineStatus');
      expect((await e.c.engineStatus()).installed, isFalse);
    });
  });

  group('create', () {
    test('saves the profile and creates a qcow2 disk of the size', () async {
      final e = await _env([]);
      final r = await e.c.create(_draft());
      expect(r.ok, isTrue);
      final p = r.profile!;
      expect(p.disks.single.virtualSizeBytes, 4 * _gib);
      expect(e.engine.disks[p.disks.single.path], 4 * _gib);
      expect((await e.repo.loadAll()).single, p);
      expect(e.c.profiles.length, 1);
    });

    test('invalid draft saves nothing and creates no disk', () async {
      final e = await _env([]);
      final r = await e.c.create(_draft(memoryMiB: 7000));
      expect(r.ok, isFalse);
      expect(r.issues.single.field, ValidationField.memory);
      expect(e.engine.disks, isEmpty);
      expect(await e.repo.loadAll(), isEmpty);
    });

    test('duplicate name is rejected', () async {
      final e = await _env([_profile('a', name: 'Dev')]);
      final r = await e.c.create(_draft(name: 'dev'));
      expect(r.issues.single.field, ValidationField.name);
    });

    test('disk creation failure leaves the library unchanged', () async {
      final e = await _env([]);
      e.engine.failOn('createDisk');
      final r = await e.c.create(_draft());
      expect(r.ok, isFalse);
      expect(r.failure?.step, 'create disk');
      expect(await e.repo.loadAll(), isEmpty);
    });

    test(
      'removable volume hosts the disk and its free space is the limit',
      () async {
        final e = await _env([]);
        e.fs.volumes = [
          const RemovableVolume(
            description: 'SD',
            path: '/sd',
            freeBytes: _gib,
          ),
        ];
        expect((await e.c.removableVolumes()).length, 1);
        final vol = (await e.c.removableVolumes()).single;
        final r = await e.c.create(_draft(), volume: vol);
        expect(r.issues.single.field, ValidationField.disk);
        expect(r.issues.single.limit, _gib);
        final ok = await e.c.create(
          _draft().copyWith(diskBytes: _gib ~/ 2),
          id: 'v1',
          volume: vol,
        );
        expect(ok.profile!.disks.single.path, '/sd/v1/disk0.qcow2');
      },
    );

    test('no removable option when no volume exists', () async {
      final e = await _env([]);
      expect(await e.c.removableVolumes(), isEmpty);
    });
  });

  group('edit', () {
    test('applies on a powered-off VM with the same validation', () async {
      final e = await _env();
      final bad = await e.c.edit('a', _draft(name: '', memoryMiB: 1024));
      expect(bad.ok, isFalse);
      final r = await e.c.edit('a', _draft(name: 'renamed'));
      expect(r.ok, isTrue);
      expect(e.c.profileOf('a')!.name, 'renamed');
      expect(e.c.profileOf('a')!.disks.single.virtualSizeBytes, 1);
    });

    test('own name is not a duplicate', () async {
      final e = await _env([_profile('a', name: 'Dev')]);
      expect((await e.c.edit('a', _draft(name: 'dev'))).ok, isTrue);
    });

    test('running VM rejects edits and keeps the profile', () async {
      final e = await _env();
      await e.c.start('a');
      final before = e.c.profileOf('a');
      final r = await e.c.edit('a', _draft(name: 'other'));
      expect(r.ok, isFalse);
      expect(e.c.profileOf('a'), before);
      expect((await e.repo.loadAll()).single, before);
    });
  });

  group('delete', () {
    test(
      'removes profile, disks and VM folder; keeps referenced media',
      () async {
        final copied = MediaRef(
          path: '/docs/vms/a/media/x.iso',
          kind: MediaKind.iso,
          copiedIntoAppStorage: true,
        );
        final e = await _env([
          _profile(
            'a',
            media: [
              const MediaRef(path: '/m.iso', kind: MediaKind.iso),
              copied,
            ],
          ),
        ]);
        e.fs.addFile(copied.path, size: 3);
        e.fs.addFile('/docs/vms/a/snapshots.json', size: 1);
        final before = e.fs.fingerprint()['/m.iso'];

        expect((await e.c.delete('a', confirmed: false)).ok, isFalse);
        expect((await e.c.delete('a', confirmed: true)).ok, isTrue);

        expect(
          e.fs.files.keys.where((k) => k.startsWith('/docs/vms/a')),
          isEmpty,
        );
        expect(e.fs.fingerprint()['/m.iso'], before);
        expect(await e.repo.loadAll(), isEmpty);
        expect(e.c.profiles, isEmpty);
      },
    );

    test('does not delete a disk path the VM does not own', () async {
      final foreign = _profile('a').copyWith(
        disks: [const DiskRef(path: '/sdcard/mine.qcow2', virtualSizeBytes: 1)],
      );
      final e = await _env([foreign]);
      e.fs.addFile('/sdcard/mine.qcow2', size: 1);
      await e.c.delete('a', confirmed: true);
      expect(e.fs.exists('/sdcard/mine.qcow2'), isTrue);
    });

    test('running VM cannot be deleted', () async {
      final e = await _env();
      await e.c.start('a');
      expect((await e.c.delete('a', confirmed: true)).ok, isFalse);
      expect(e.c.profileOf('a'), isNotNull);
    });
  });

  group('clone, search, export, import', () {
    test(
      'clone has a new id, unique name, same settings and a disk copy',
      () async {
        final e = await _env([_profile('a', name: 'Dev')]);
        final r = await e.c.clone('a');
        final c = r.profile!;
        expect(c.id, isNot('a'));
        expect(c.name, 'Dev copy');
        expect(c.cpuCount, 2);
        expect(c.disks.single.path, '/docs/vms/${c.id}/disks/disk0.qcow2');
        expect(e.fs.contents[c.disks.single.path], 'disk-a');
        expect((await e.c.clone('a')).profile!.name, 'Dev copy 2');
      },
    );

    test('failed clone cleans up and adds nothing', () async {
      final e = await _env();
      e.fs.deleteFile('/docs/vms/a/disks/disk0.qcow2');
      final r = await e.c.clone('a');
      expect(r.ok, isFalse);
      expect(e.c.profiles.length, 1);
    });

    test('search ignores case', () async {
      final e = await _env([
        _profile('a', name: 'Ubuntu Dev'),
        _profile('b', name: 'Windows'),
      ]);
      expect(e.c.search('UBUN').map((p) => p.id), ['a']);
      expect(e.c.search('').length, 2);
    });

    test('export then import adds the profile with a fresh id and marks '
        'missing files', () async {
      final e = await _env([_profile('a', name: 'Dev')]);
      final json = e.c.exportProfile('a')!;
      expect(json, isNot(contains('disk-a')));
      e.fs.deleteFile('/m.iso');
      final r = await e.c.importProfile(json);
      final imp = r.profile!;
      expect(imp.id, isNot('a'));
      expect(imp.name, 'Dev copy');
      expect(imp.media.single.status, MediaStatus.missing);
      expect(imp.disks.single.status, MediaStatus.present);
      expect(e.c.profiles.length, 2);
    });

    test('malformed import is rejected and names the problem', () async {
      final e = await _env();
      final r = await e.c.importProfile('{"schemaVersion": 99}');
      expect(r.ok, isFalse);
      expect(r.message, contains('99'));
      expect(e.c.profiles.length, 1);
    });
  });

  group('media', () {
    PickedMedia pick(String name, {int size = 100}) => PickedMedia(
      uri: 'content://$name',
      name: name,
      size: size,
      supported: true,
    );

    test('attach in place references the uri without copying', () async {
      final e = await _env();
      e.fs.uris['content://x.iso'] = 100;
      final r = await e.c.attachMedia('a', pick('x.iso'));
      expect(
        r.profile!.media.last,
        const MediaRef(
          path: '/storage/emulated/0/x.iso',
          kind: MediaKind.iso,
          displayName: 'x.iso',
        ),
      );
      expect(e.fs.files.keys.where((k) => k.contains('/media/')), isEmpty);
    });
    test('attach in place without All-files access offers the copy', () async {
      final e = await _env();
      e.fs.uris['content://x.iso'] = 100;
      e.fs.allFilesAccess = false;
      final prep = await e.c.prepareMedia(pick('x.iso'), vmId: 'a');
      expect(prep.ok, isFalse);
      expect(prep.problem, MediaProblem.allFilesAccess);
      expect(prep.copyWouldHelp, isTrue);
      expect(prep.message, contains('All-files access'));
      final r = await e.c.attachMedia('a', pick('x.iso'));
      expect(r.ok, isFalse);
      expect(e.c.profileOf('a')!.media.length, 1);
    });
    test('attach in place with an unresolvable path offers the copy', () async {
      final e = await _env();
      final prep = await e.c.prepareMedia(pick('cloud.iso'), vmId: 'a');
      expect(prep.problem, MediaProblem.unresolvable);
      expect(prep.copyWouldHelp, isTrue);
    });
    test('copy works without All-files access', () async {
      final e = await _env();
      e.fs.uris['content://x.iso'] = 100;
      e.fs.allFilesAccess = false;
      final r = await e.c.attachMedia('a', pick('x.iso'), copy: true);
      expect(r.ok, isTrue);
    });

    test('unsupported format is rejected with the supported list', () async {
      final e = await _env();
      final r = await e.c.attachMedia('a', pick('x.zip'));
      expect(r.ok, isFalse);
      expect(r.message, contains('.iso'));
      expect(e.c.profileOf('a')!.media.length, 1);
    });

    test('copy stores the file in the VM media folder', () async {
      final e = await _env();
      e.fs.uris['content://x.iso'] = 100;
      final r = await e.c.attachMedia('a', pick('x.iso'), copy: true);
      final m = r.profile!.media.last;
      expect(m.copiedIntoAppStorage, isTrue);
      expect(m.path, '/docs/vms/a/media/x.iso');
      expect(m.displayName, 'x.iso');
      expect(e.fs.exists(m.path), isTrue);
    });
    test('picked display name is kept apart from an opaque uri', () async {
      final e = await _env();
      e.fs.uris['content://com.x/document/msf:1000254595'] = 100;
      final r = await e.c.attachMedia(
        'a',
        const PickedMedia(
          uri: 'content://com.x/document/msf:1000254595',
          name: 'ubuntu.iso',
          size: 100,
          supported: true,
        ),
      );
      final m = r.profile!.media.last;
      expect(m.path, startsWith('/storage/emulated/0/'));
      expect(m.label, 'ubuntu.iso');
    });

    test('copy with too little space is rejected with both amounts, '
        'copies nothing', () async {
      final e = await _env();
      e.fs.uris['content://x.iso'] = 100;
      e.fs.freeBytes = 40;
      final r = await e.c.attachMedia('a', pick('x.iso'), copy: true);
      expect(r.ok, isFalse);
      expect(r.message, allOf(contains('100'), contains('40')));
      expect(e.fs.exists('/docs/vms/a/media/x.iso'), isFalse);
    });

    test('copy progress events become percentages', () async {
      final e = await _env();
      final got = <int>[];
      e.c.copyProgress.listen((p) => got.add(p.percent));
      e.engine.emit(const CopyProgressEvent('/d', 25, 100));
      e.engine.emit(const CopyProgressEvent('/d', 5, -1));
      e.engine.emit(const CopyProgressEvent('/d', 100, 100));
      await Future<void>.delayed(Duration.zero);
      expect(got, [25, 100]);
    });

    test('detach removes only the reference', () async {
      final e = await _env();
      final before = e.fs.fingerprint();
      final r = await e.c.detachMedia('a', '/m.iso');
      expect(r.profile!.media, isEmpty);
      expect(e.fs.fingerprint(), before);
    });

    test('attach and detach need a powered-off VM', () async {
      final e = await _env();
      await e.c.start('a');
      expect((await e.c.detachMedia('a', '/m.iso')).ok, isFalse);
    });

    test('removing a shared folder keeps the others and all files', () async {
      const s1 = SharedFolder(androidPath: '/sdcard/a', mountTag: 'a');
      const s2 = SharedFolder(androidPath: '/sdcard/b', mountTag: 'b');
      final e = await _env([
        _profile('a', shares: [s1, s2]),
      ]);
      e.fs.addFile('/sdcard/a/f.txt', size: 1);
      final before = e.fs.fingerprint();
      final r = await e.c.removeSharedFolder('a', s1);
      expect(r.profile!.sharedFolders, [s2]);
      expect(e.fs.fingerprint(), before);
    });
  });

  group('content:// media at start', () {
    test('a legacy uri is resolved to a real path, never an fd path', () async {
      final e = await _env([
        _profile(
          'a',
          media: const [MediaRef(path: 'content://x.iso', kind: MediaKind.iso)],
        ),
      ]);
      e.fs.uris['content://x.iso'] = 1;
      final r = await e.c.start('a');
      expect(r.ok, isTrue);
      final args = e.engine.started.single.args.join(' ');
      expect(args, contains('file=/storage/emulated/0/x.iso,'));
      expect(args, isNot(contains('/proc/self/fd')));
      expect(args, isNot(contains('content://')));
      expect(e.c.profileOf('a')!.media.single.path, 'content://x.iso');
    });
    test('an unresolvable uri blocks start and names it', () async {
      final e = await _env([
        _profile(
          'a',
          media: const [
            MediaRef(path: 'content://gone.iso', kind: MediaKind.iso),
          ],
        ),
      ]);
      final r = await e.c.start('a');
      expect(r.failure?.step, 'media');
      expect(r.message, contains('content://gone.iso'));
      expect(r.message, contains('copy it into app storage'));
      expect(e.c.stateOf('a'), VmState.poweredOff);
    });
    test('without All-files access the start message says so', () async {
      final e = await _env([
        _profile(
          'a',
          media: const [MediaRef(path: 'content://x.iso', kind: MediaKind.iso)],
        ),
      ]);
      e.fs.uris['content://x.iso'] = 1;
      e.fs.allFilesAccess = false;
      final r = await e.c.start('a');
      expect(r.failure?.step, 'media');
      expect(r.message, contains('All-files access'));
      expect(e.engine.started, isEmpty);
    });
  });
  group('compatibility detection', () {
    test('detect probes once, refresh probes again and keeps values on '
        'failure', () async {
      final e = await _env();
      final probe = FakeHostProbe(capabilities: _host);
      final c = VmManagerController(
        repository: e.repo,
        engine: e.engine,
        files: e.fs,
        hostProbe: probe,
        layout: const VmLayout('/docs'),
        pathExists: (p) async => true,
        fileOps: FakeFileOps(e.fs),
      );
      expect(c.report, isNull);
      await c.detectCapabilities();
      await c.detectCapabilities();
      expect(probe.probeCalls, 1);
      expect(c.report!.host, _host);
      await c.refreshCapabilities();
      expect(probe.probeCalls, 2);
      probe.failWith = PlatformException(code: 'x');
      final r = await c.refreshCapabilities();
      expect(r.host, _host);
      await c.dispose();
    });
  });
}
