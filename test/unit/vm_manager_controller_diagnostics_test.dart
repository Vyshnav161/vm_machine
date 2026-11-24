import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart'
    hide expect, test, group, setUp, expectLater;
import 'package:glados/glados.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/services.dart';

import '../fakes/fakes.dart';

const _gib = 1024 * 1024 * 1024;

class _Signals implements HostSignalService {
  final ctrl = StreamController<HostSignals>.broadcast();
  @override
  Stream<HostSignals> get signals => ctrl.stream;
}

VmProfile _profile(String id) => VmProfile(
  id: id,
  name: 'vm $id',
  guestOs: GuestOs.linux,
  guestArch: GuestArch.x86_64,
  cpuCount: 2,
  memoryMiB: 1024,
  disks: [DiskRef(path: '/d/$id.qcow2', virtualSizeBytes: 1)],
  media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
  createdAt: DateTime.utc(2025),
);

class _Env {
  _Env({this.logMax = 16}) {
    fs.addFile('/m.iso');
    for (final id in ['a', 'b']) {
      fs.addFile('/d/$id.qcow2', size: 10, content: 'disk-$id');
      repo.save(_profile(id));
    }
    c = VmManagerController(
      repository: repo,
      engine: engine,
      files: fs,
      hostProbe: FakeHostProbe(
        capabilities: const HostCapabilities(
          arch: Known(GuestArch.arm64),
          totalRamBytes: Known(8 * _gib),
          freeStorageBytes: Known(100 * _gib),
          cpuCores: Known(8),
          hardwareVirtualization: Known(false),
        ),
      ),
      layout: const VmLayout('/docs'),
      pathExists: (p) async => fs.exists(p),
      fileOps: ops = FakeFileOps(fs),
      hostSignals: signals,
      logMaxBytes: logMax,
      now: () => DateTime.utc(2025, 1, 2),
    );
  }
  final int logMax;
  final repo = MemoryVmRepository();
  final engine = FakeEngineService();
  final fs = FakeFileSystem(freeBytes: 100 * _gib);
  final signals = _Signals();
  late final FakeFileOps ops;
  late final VmManagerController c;

  Future<void> run(String id) async {
    await c.start(id);
    engine.emit(EngineStateChanged(id, 'running'));
    await Future<void>.delayed(Duration.zero);
  }
}

Future<_Env> _env({int logMax = 16}) async {
  final e = _Env(logMax: logMax);
  await e.c.load();
  return e;
}

void main() {
  group('snapshots', () {
    test('create on a running VM records name and timestamp', () async {
      final e = await _env();
      await e.run('a');
      final r = await e.c.createSnapshot('a', ' s1 ');
      expect(r.ok, isTrue);
      expect(e.engine.qmpCommands, contains('savevm'));
      final list = await e.c.snapshots('a');
      expect(list.single.name, 's1');
      expect(list.single.createdAt, DateTime.utc(2025, 1, 2));
      expect(e.fs.exists('/docs/vms/a/snapshots.json'), isTrue);
    });

    test('create is rejected when powered off or on a duplicate', () async {
      final e = await _env();
      expect((await e.c.createSnapshot('a', 's')).ok, isFalse);
      await e.run('a');
      await e.c.createSnapshot('a', 's');
      expect((await e.c.createSnapshot('a', 's')).ok, isFalse);
      expect(await e.c.snapshots('a'), hasLength(1));
    });

    test('create with too little storage shows both amounts', () async {
      final e = await _env();
      await e.run('a');
      e.fs.freeBytes = 1000;
      final r = await e.c.createSnapshot('a', 's');
      expect(r.ok, isFalse);
      expect(r.message, contains('${1024 * 1024 * 1024}'));
      expect(r.message, contains('1000'));
      expect(e.engine.qmpCommands, isNot(contains('savevm')));
    });

    test('engine failure records nothing', () async {
      final e = await _env();
      await e.run('a');
      e.engine.failOn('snapshotCreate');
      final r = await e.c.createSnapshot('a', 's');
      expect(r.ok, isFalse);
      expect(await e.c.snapshots('a'), isEmpty);
    });

    test('restore needs confirmation and a powered-off VM', () async {
      final e = await _env();
      e.engine.diskSnapshots['/d/a.qcow2'] = ['s'];
      await e.c.snapshots('a');
      await e.run('a');
      await e.c.createSnapshot('a', 's');
      expect(
        (await e.c.restoreSnapshot('a', 's', confirmed: true)).ok,
        isFalse,
      );
      await e.c.forceStop('a', confirmed: true);
      expect(
        (await e.c.restoreSnapshot('a', 's', confirmed: false)).ok,
        isFalse,
      );
      expect(
        (await e.c.restoreSnapshot('a', 'nope', confirmed: true)).ok,
        isFalse,
      );
    });

    test('failed restore leaves disk unchanged and shows the reason', () async {
      final e = await _env();
      await e.run('a');
      await e.c.createSnapshot('a', 's');
      await e.c.forceStop('a', confirmed: true);
      final before = e.fs.fingerprint()..remove('/docs/vms/a/snapshots.json');
      // The fake has no such snapshot on disk, so the engine fails.
      final r = await e.c.restoreSnapshot('a', 's', confirmed: true);
      expect(r.ok, isFalse);
      expect(r.message, 'no snapshot');
      expect(e.fs.fingerprint()..remove('/docs/vms/a/snapshots.json'), before);
    });

    test('delete removes only the chosen snapshot', () async {
      final e = await _env();
      await e.run('a');
      await e.c.createSnapshot('a', 's1');
      await e.c.createSnapshot('a', 's2');
      await e.c.forceStop('a', confirmed: true);
      expect(
        (await e.c.deleteSnapshot('a', 's1', confirmed: false)).ok,
        isFalse,
      );
      expect((await e.c.deleteSnapshot('a', 's1', confirmed: true)).ok, isTrue);
      expect([for (final s in await e.c.snapshots('a')) s.name], ['s2']);
      expect(await e.c.snapshotBytes('a'), 1024 * 1024 * 1024);
    });
  });

  group('host signals', () {
    test('severe thermal pauses all running VMs and notifies once', () async {
      final e = await _env();
      await e.run('a');
      await e.run('b');
      final notices = <HostNotice>[];
      e.c.notices.listen(notices.add);
      e.signals.ctrl.add(const HostSignals(thermal: ThermalStatus.severe));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(e.c.stateOf('a'), VmState.paused);
      expect(e.c.stateOf('b'), VmState.paused);
      expect(notices.map((n) => n.kind), [HostNoticeKind.thermalPause]);
    });

    test('critical trim snapshots then pauses', () async {
      final e = await _env();
      await e.run('a');
      await e.c.handleHostSignals(const HostSignals(trimMemoryLevel: 15));
      expect(e.engine.qmpCommands, ['savevm', 'stop']);
      expect(e.c.stateOf('a'), VmState.paused);
      expect(await e.c.snapshots('a'), hasLength(1));
    });

    test('low battery notifies without pausing', () async {
      final e = await _env();
      await e.run('a');
      final notices = <HostNotice>[];
      e.c.notices.listen(notices.add);
      await e.c.handleHostSignals(
        const HostSignals(batteryPercent: 15, charging: false),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.kind, HostNoticeKind.batteryLow);
      expect(notices.single.vmIds, ['a']);
      expect(e.c.stateOf('a'), VmState.running);
    });

    test('low storage pauses and warns', () async {
      final e = await _env();
      await e.run('a');
      await e.c.handleHostSignals(const HostSignals(freeStorageBytes: 1));
      expect(e.c.stateOf('a'), VmState.paused);
    });

    test('network loss flags the guest without changing state', () async {
      final e = await _env();
      await e.run('a');
      await e.c.handleHostSignals(const HostSignals(networkConnected: false));
      expect(e.c.runtimeOf('a').networkConnected, isFalse);
      expect(e.c.stateOf('a'), VmState.running);
      await e.c.handleHostSignals(const HostSignals(networkConnected: true));
      expect(e.c.runtimeOf('a').networkConnected, isTrue);
    });

    test('powered-off VMs are never targeted', () async {
      final e = await _env();
      await e.c.handleHostSignals(
        const HostSignals(thermal: ThermalStatus.emergency),
      );
      expect(e.engine.calls, isNot(contains('pause')));
    });
  });

  group('diagnostics', () {
    test('stats stream reports usage and ends when the VM stops', () async {
      final e = await _env();
      e.engine.statsResult = const EngineStats(
        cpuPercent: 12.5,
        memBytes: 512 * 1024 * 1024,
      );
      await e.run('a');
      final samples = <VmStats>[];
      final done = e.c
          .statsStream('a', interval: const Duration(milliseconds: 1))
          .listen(samples.add)
          .asFuture<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(samples, isNotEmpty);
      expect(samples.first.text, contains('12.5'));
      expect(samples.first.text, contains('512 MiB'));
      expect(samples.first.text, contains('softwareEmulation'));
      expect(samples.first.crossArch, isTrue);
      await e.c.forceStop('a', confirmed: true);
      await done.timeout(const Duration(seconds: 2));
    });

    test('view log returns the newest bytes and trims the file', () async {
      final e = await _env(logMax: 8);
      e.ops.fs.data['/docs/logs/a.log'] = Uint8List.fromList(
        utf8.encode('0123456789abcdef'),
      );
      expect(await e.c.viewLog('a'), '89abcdef');
      expect(e.fs.data['/docs/logs/a.log'], hasLength(8));
    });

    test('view log is empty without a file; share needs a log', () async {
      final e = await _env();
      expect(await e.c.viewLog('a'), '');
      expect((await e.c.shareLog('a')).ok, isFalse);
      e.fs.data['/docs/logs/a.log'] = Uint8List.fromList([65]);
      e.fs.addFile('/docs/logs/a.log', size: 1);
      expect((await e.c.shareLog('a')).ok, isTrue);
      expect(e.fs.sharedLogs, ['/docs/logs/a.log']);
    });
  });
}
