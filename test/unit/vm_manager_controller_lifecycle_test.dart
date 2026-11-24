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

VmProfile _profile(String id, {int memoryMiB = 1024, String name = 'vm'}) =>
    VmProfile(
      id: id,
      name: name,
      guestOs: GuestOs.linux,
      guestArch: GuestArch.x86_64,
      cpuCount: 2,
      memoryMiB: memoryMiB,
      disks: [DiskRef(path: '/d/$id.qcow2', virtualSizeBytes: 1)],
      media: const [MediaRef(path: '/m.iso', kind: MediaKind.iso)],
      createdAt: DateTime.utc(2025),
    );

class _Env {
  _Env({List<VmProfile>? profiles, HostCapabilities? host}) {
    fs.addFile('/m.iso');
    for (final p in profiles ?? [_profile('a')]) {
      fs.addFile(p.disks.first.path, size: 10, content: 'disk-${p.id}');
      repo.save(p);
    }
    probe = FakeHostProbe(
      capabilities:
          host ??
          const HostCapabilities(
            arch: Known(GuestArch.arm64),
            totalRamBytes: Known(8 * _gib),
            freeStorageBytes: Known(100 * _gib),
            cpuCores: Known(8),
            hardwareVirtualization: Known(false),
          ),
    );
    c = VmManagerController(
      repository: repo,
      engine: engine,
      files: fs,
      hostProbe: probe,
      layout: const VmLayout('/docs'),
      pathExists: (p) async => fs.exists(p),
    );
  }

  final repo = MemoryVmRepository();
  final engine = FakeEngineService();
  final fs = FakeFileSystem();
  late final FakeHostProbe probe;
  late final VmManagerController c;
}

Future<_Env> _env({List<VmProfile>? profiles, HostCapabilities? host}) async {
  final e = _Env(profiles: profiles, host: host);
  await e.c.load();
  return e;
}

Future<_Env> _running() async {
  final e = await _env();
  await e.c.start('a');
  e.engine.emit(const EngineStateChanged('a', 'running'));
  await Future<void>.delayed(Duration.zero);
  expect(e.c.stateOf('a'), VmState.running);
  return e;
}

void main() {
  group('start sequence', () {
    test(
      'starts the engine with the launch spec and moves to starting',
      () async {
        final e = await _env();
        final r = await e.c.start('a');
        expect(r.ok, isTrue);
        expect(e.c.stateOf('a'), VmState.starting);
        final req = e.engine.started.single;
        expect(req.id, 'a');
        expect(req.executable, 'libqemu-system-x86_64.so');
        expect(req.qmpSocketPath, '/docs/vms/a/run/qmp.sock');
        expect(req.logPath, '/docs/logs/a.log');
      },
    );

    test('engine ready event moves to running', () async {
      final e = await _running();
      expect(e.c.stateOf('a'), VmState.running);
    });

    test(
      'missing media blocks start, names the file, stays powered off',
      () async {
        final e = await _env();
        e.fs.deleteFile('/m.iso');
        final r = await e.c.start('a');
        expect(r.ok, isFalse);
        expect(r.failure?.step, 'media');
        expect(r.message, contains('/m.iso'));
        expect(e.c.stateOf('a'), VmState.poweredOff);
        expect(e.engine.started, isEmpty);
      },
    );

    test('combined memory above 75 percent blocks start', () async {
      final e = await _env(
        profiles: [
          _profile('a', memoryMiB: 4096),
          _profile('b', memoryMiB: 4096),
        ],
      );
      expect((await e.c.start('a')).ok, isTrue);
      final r = await e.c.start('b');
      expect(r.ok, isFalse);
      expect(r.failure?.step, 'eligibility');
      expect(e.c.stateOf('b'), VmState.poweredOff);
    });

    test('engine failure becomes StartFailure and Error state', () async {
      final e = await _env();
      e.engine.failOn('start');
      final r = await e.c.start('a');
      expect(r.ok, isFalse);
      expect(r.failure?.step, 'engine');
      expect(r.message, contains('Failed at step "engine"'));
      expect(e.c.stateOf('a'), VmState.error);
      expect(e.c.runtimeOf('a').lastFailure, r.failure);
    });

    test(
      'cross-architecture failure message carries the slow boot hint',
      () async {
        final e = await _env();
        e.engine.failOn('start');
        final r = await e.c.start('a');
        expect(r.message, contains(FailureMessage.slowBootHint));
      },
    );

    test(
      'start from Error is allowed; start while running is rejected',
      () async {
        final e = await _env();
        e.engine.failOn('start');
        await e.c.start('a');
        e.engine.clearFailures();
        expect((await e.c.start('a')).ok, isTrue);
        expect(e.c.stateOf('a'), VmState.starting);
        expect((await e.c.start('a')).ok, isFalse);
      },
    );
  });

  group('lifecycle commands', () {
    test('pause and resume send stop and cont', () async {
      final e = await _running();
      expect((await e.c.pause('a')).ok, isTrue);
      expect(e.c.stateOf('a'), VmState.paused);
      expect((await e.c.resume('a')).ok, isTrue);
      expect(e.c.stateOf('a'), VmState.running);
      expect(e.engine.qmpCommands, ['stop', 'cont']);
    });

    test('shutdown sends system_powerdown; clean exit powers off', () async {
      final e = await _running();
      await e.c.shutdown('a');
      expect(e.engine.qmpCommands, ['system_powerdown']);
      expect(e.c.stateOf('a'), VmState.stopping);
      e.engine.emit(
        const EngineExit(
          id: 'a',
          crashed: false,
          exitCode: 0,
          kind: 'clean',
          message: '',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(e.c.stateOf('a'), VmState.poweredOff);
    });

    test(
      'restart sends system_reset and returns to running on RESET',
      () async {
        final e = await _running();
        await e.c.restart('a');
        expect(e.engine.qmpCommands, ['system_reset']);
        expect(e.c.stateOf('a'), VmState.starting);
        e.engine.emit(const EngineQmpEvent('a', 'RESET', {}));
        await Future<void>.delayed(Duration.zero);
        expect(e.c.stateOf('a'), VmState.running);
      },
    );

    test('force stop needs confirmation and sends no QMP command', () async {
      final e = await _running();
      expect((await e.c.forceStop('a', confirmed: false)).ok, isFalse);
      expect(e.c.stateOf('a'), VmState.running);
      expect((await e.c.forceStop('a', confirmed: true)).ok, isTrue);
      expect(e.engine.calls, contains('kill'));
      expect(e.engine.qmpCommands, isEmpty);
      expect(e.c.stateOf('a'), VmState.poweredOff);
    });

    test('force stop that cannot kill the process ends in Error', () async {
      final e = await _running();
      e.engine.killSucceeds = false;
      final r = await e.c.forceStop('a', confirmed: true);
      expect(r.ok, isFalse);
      expect(e.c.stateOf('a'), VmState.error);
    });

    test('failed engine command keeps the previous state', () async {
      final e = await _running();
      e.engine.failOn('pause');
      expect((await e.c.pause('a')).ok, isFalse);
      expect(e.c.stateOf('a'), VmState.running);
    });

    test('illegal command is rejected without calling the engine', () async {
      final e = await _env();
      expect((await e.c.pause('a')).ok, isFalse);
      expect(e.engine.calls, isEmpty);
    });

    test('guest power off event returns to powered off', () async {
      final e = await _running();
      e.engine.emit(const EngineQmpEvent('a', 'SHUTDOWN', {}));
      await Future<void>.delayed(Duration.zero);
      expect(e.c.stateOf('a'), VmState.poweredOff);
    });
  });

  group('unexpected exit', () {
    test(
      'crash sets Error with the reason and leaves disks unchanged',
      () async {
        final e = await _running();
        final before = e.fs.fingerprint();
        e.engine.emit(
          const EngineExit(
            id: 'a',
            crashed: true,
            signal: 11,
            signalName: 'SIGSEGV',
            kind: 'signal',
            message: 'QEMU died with SIGSEGV',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(e.c.stateOf('a'), VmState.error);
        expect(e.c.runtimeOf('a').errorReason, 'QEMU died with SIGSEGV');
        expect(e.fs.fingerprint(), before);
        expect(e.engine.disks, isEmpty);
        expect(e.engine.diskSnapshots, isEmpty);
      },
    );

    test('non-zero exit while running sets Error', () async {
      final e = await _running();
      e.engine.emit(
        const EngineExit(
          id: 'a',
          crashed: false,
          exitCode: 1,
          kind: 'error',
          message: 'bad',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(e.c.stateOf('a'), VmState.error);
      expect(e.c.runtimeOf('a').errorReason, 'bad');
    });

    test('startFailed event records the failing step', () async {
      final e = await _env();
      await e.c.start('a');
      e.engine.emit(const EngineStartFailed('a', 'qmp', 'no socket'));
      await Future<void>.delayed(Duration.zero);
      expect(e.c.stateOf('a'), VmState.error);
      expect(
        e.c.runtimeOf('a').lastFailure,
        const StartFailure('qmp', 'no socket'),
      );
    });
  });

  group('command gating', () {
    test('rejected commands never reach the engine', () async {
      for (final state in VmState.values) {
        await _checkGating(state);
      }
    });
  });
}

Future<void> _checkGating(VmState state) async {
  {
    {
      final e = await _env();
      await e.c.start('a');
      // Drive to the requested state through engine events where possible.
      switch (state) {
        case VmState.poweredOff:
          e.engine.emit(const EngineStateChanged('a', 'running'));
          e.engine.emit(const EngineQmpEvent('a', 'SHUTDOWN', {}));
        case VmState.running:
          e.engine.emit(const EngineStateChanged('a', 'running'));
        case VmState.paused:
          e.engine.emit(const EngineStateChanged('a', 'running'));
          e.engine.emit(const EngineStateChanged('a', 'paused'));
        case VmState.stopping:
          e.engine.emit(const EngineStateChanged('a', 'running'));
          e.engine.emit(const EngineStateChanged('a', 'stopping'));
        case VmState.error:
          e.engine.emit(const EngineStartFailed('a', 'qmp', 'x'));
        case VmState.starting:
          break;
      }
      await Future<void>.delayed(Duration.zero);
      expect(e.c.stateOf('a'), state);
      e.engine.calls.clear();
      final r = await e.c.pause('a');
      expect(r.ok, state == VmState.running);
      expect(e.engine.calls.isEmpty, !r.ok);
    }
  }
}
