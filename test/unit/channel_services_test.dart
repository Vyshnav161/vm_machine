import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart'
    hide expect, test, group, setUp, expectLater;
import 'package:glados/glados.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/services.dart';

import '../fakes/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  void mock(String channel, Object? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(MethodChannel(channel), (c) async {
      calls.add(c);
      return handler(c);
    });
  }

  setUp(calls.clear);

  group('channel contract', () {
    test('host probe maps nulls to Unknown', () async {
      mock(
        'vm/host',
        (_) => {
          'arch': 'arm64',
          'totalRam': 8000000000,
          'freeStorage': null,
          'cores': 8,
          'virt': null,
        },
      );
      final caps = await ChannelHostProbeService().probe();
      expect(
        caps,
        const HostCapabilities(
          arch: Known(GuestArch.arm64),
          totalRamBytes: Known(8000000000),
          cpuCores: Known(8),
        ),
      );
    });

    test('engine start sends contract keys and returns pid', () async {
      mock('vm/engine', (_) => {'pid': 42});
      final pid = await ChannelEngineService().start(
        const EngineStartRequest(
          id: 'a',
          name: 'A',
          executable: 'libqemu-system-aarch64.so',
          args: ['-m', '512'],
          qmpSocketPath: '/q',
          vncSocketPath: '/v',
          logPath: '/l',
        ),
      );
      expect(pid, 42);
      expect(calls.single.method, 'start');
      expect((calls.single.arguments as Map).keys.toSet(), {
        'id',
        'name',
        'executable',
        'args',
        'qmpSocketPath',
        'vncSocketPath',
        'logPath',
      });
    });

    test('engine snapshot and powerdown arguments', () async {
      mock('vm/engine', (_) => null);
      final e = ChannelEngineService();
      await e.powerdown('a');
      await e.snapshotDelete('a', 's', disk: '/d');
      expect(calls[0].arguments, {'id': 'a'});
      expect(calls[1].arguments, {'id': 'a', 'name': 's', 'disk': '/d'});
    });

    test('platform error codes propagate', () async {
      mock('vm/engine', (_) => throw PlatformException(code: 'not_running'));
      await expectLater(
        ChannelEngineService().pause('a'),
        throwsA(isA<PlatformException>()),
      );
    });

    test('files copyMedia parses no_space result', () async {
      mock(
        'vm/files',
        (_) => {
          'ok': false,
          'error': 'no_space',
          'required': 10,
          'available': 5,
        },
      );
      final r = await ChannelFileService().copyMedia('u', '/d');
      expect(r.ok, false);
      expect((r.error, r.required, r.available), ('no_space', 10, 5));
    });

    test('display createTexture and pointer', () async {
      mock('vm/display', (c) => c.method == 'createTexture' ? 7 : true);
      final d = ChannelDisplayService();
      expect(await d.createTexture('a'), 7);
      expect(await d.sendPointer('a', 1, 2, 1), true);
      expect(calls[1].arguments, {'id': 'a', 'x': 1, 'y': 2, 'buttons': 1});
    });
  });

  group('event parsing', () {
    test('exited and crashed', () {
      final e =
          parseEngineEvent({
                'type': 'crashed',
                'id': 'a',
                'exitCode': null,
                'signal': 11,
                'signalName': 'SIGSEGV',
                'kind': 'signal',
                'message': 'm',
              })
              as EngineExit;
      expect(
        (e.crashed, e.signal, e.exitCode, e.kind),
        (true, 11, null, 'signal'),
      );
    });

    test('unknown type returns null', () {
      expect(parseEngineEvent({'type': 'zzz'}), isNull);
    });

    test('host signals include networkConnected', () {
      final s = parseHostSignals({
        'thermal': 'severe',
        'batteryPercent': 10,
        'networkConnected': false,
      });
      expect(s.thermal, ThermalStatus.severe);
      expect(s.networkConnected, false);
    });
  });

  group('fakes', () {
    test('FakeEngineService records QMP and fails on demand', () async {
      final e = FakeEngineService();
      await e.start(
        const EngineStartRequest(
          id: 'a',
          name: 'A',
          executable: 'x',
          args: [],
          qmpSocketPath: '/q',
          vncSocketPath: '/v',
          logPath: '/l',
        ),
      );
      await e.powerdown('a');
      await e.kill('a');
      expect(e.qmpCommands, ['system_powerdown']);
      e.failOn('start');
      await expectLater(
        e.start(
          const EngineStartRequest(
            id: 'b',
            name: 'B',
            executable: 'x',
            args: [],
            qmpSocketPath: '/q',
            vncSocketPath: '/v',
            logPath: '/l',
          ),
        ),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  Glados(any.int).test('HostSignals equality includes networkConnected', (n) {
    final a = HostSignals(batteryPercent: n, networkConnected: true);
    final b = HostSignals(batteryPercent: n, networkConnected: false);
    expect(a == b, false);
    expect(a, HostSignals(batteryPercent: n, networkConnected: true));
  });
}
