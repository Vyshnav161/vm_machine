import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vm_machine/controller/vm_layout.dart';
import 'package:vm_machine/controller/vm_manager_controller.dart';
import 'package:vm_machine/data/vm_repository.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/display_service.dart';
import 'package:vm_machine/services/providers.dart';
import 'package:vm_machine/ui/providers.dart';
import 'package:vm_machine/ui/screens/vm_console_screen.dart';
import 'package:vm_machine/ui/theme/theme.dart';

import '../fakes/fakes.dart';

class _FakeDisplay implements DisplayService {
  final List<(int, bool)> keys = [];
  final List<(int, int, int)> pointers = [];

  @override
  Future<bool> sendKey(String id, int keysym, bool down) async {
    keys.add((keysym, down));
    return true;
  }

  @override
  Future<int> createTexture(String id, {String? socketPath}) async => 1;
  @override
  Future<bool> sendPointer(String id, int x, int y, int buttons) async {
    pointers.add((x, y, buttons));
    return true;
  }

  @override
  Future<bool> screenshot(String id, String path) async => true;
  @override
  Future<TextureSize> textureSize(String id) async =>
      const TextureSize(800, 600);
  @override
  Future<void> disposeTexture(String id) async {}
  @override
  Future<MirrorStatus> mirrorStatus() async =>
      const MirrorStatus(externalConnected: false, mirroring: false);
  @override
  Future<bool> mirrorStart(String id) async => false;
  @override
  Future<void> mirrorStop() async {}
}

VmProfile _vm() => VmProfile(
  id: 'a',
  name: 'Alpha',
  guestOs: GuestOs.linux,
  guestArch: GuestArch.x86_64,
  cpuCount: 2,
  memoryMiB: 1024,
  createdAt: DateTime.utc(2025),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => lastTrackpadMode = false);

  Future<_FakeDisplay> pump(WidgetTester tester, VmState state) async {
    final repo = MemoryVmRepository();
    await repo.save(_vm());
    final fs = FakeFileSystem();
    final controller = VmManagerController(
      repository: repo,
      engine: FakeEngineService(),
      files: fs,
      fileOps: FakeFileOps(fs),
      hostProbe: FakeHostProbe(capabilities: const HostCapabilities()),
      layout: const VmLayout('/docs'),
      pathExists: (_) async => false,
    );
    await controller.load();
    final display = _FakeDisplay();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vmManagerControllerProvider.overrideWithValue(controller),
          displayServiceProvider.overrideWithValue(display),
          vmRuntimeProvider('a').overrideWith((ref) => VmRuntime(state: state)),
          vmStatsProvider('a').overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const VmConsoleScreen(vmId: 'a'),
        ),
      ),
    );
    await _settle(tester);
    return display;
  }

  testWidgets('keys send the right keysyms, down then up', (tester) async {
    final display = await pump(tester, VmState.running);
    final expected = {
      'key-esc': 0xff1b,
      'key-up': 0xff52,
      'key-down': 0xff54,
      'key-left': 0xff51,
      'key-right': 0xff53,
      'key-enter': 0xff0d,
    };
    for (final e in expected.entries) {
      display.keys.clear();
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(Key(e.key))),
      );
      await g.up();
      await tester.pump();
      expect(display.keys, [(e.value, true), (e.value, false)], reason: e.key);
    }
  });

  testWidgets('holding an arrow repeats', (tester) async {
    final display = await pump(tester, VmState.running);
    display.keys.clear();
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('key-left'))),
    );
    await tester.pump(const Duration(milliseconds: 900));
    await g.up();
    await tester.pump();
    final downs = display.keys.where((k) => k.$1 == 0xff51 && k.$2).length;
    expect(downs, greaterThan(3));
    final count = display.keys.length;
    await tester.pump(const Duration(milliseconds: 500));
    expect(display.keys.length, count, reason: 'repeat stops on release');
  });

  testWidgets('keys do nothing while the VM is off', (tester) async {
    final display = await pump(tester, VmState.poweredOff);
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('key-enter'))),
    );
    await g.up();
    await tester.pump();
    expect(display.keys, isEmpty);
  });

  testWidgets('popup enables controls by state (running)', (tester) async {
    await pump(tester, VmState.running);
    await tester.tap(find.byKey(const Key('key-more')));
    await _settle(tester);
    for (final label in [
      'Pause',
      'Shut down',
      'Restart',
      'Force stop',
      'Keyboard',
      'Keys',
      'Screenshot',
      'External display',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Start'), findsNothing);
    expect(_opacityOf(tester, 'Restart'), 1);
  });

  testWidgets('popup disables live controls when powered off', (tester) async {
    await pump(tester, VmState.poweredOff);
    await tester.tap(find.byKey(const Key('key-more')));
    await _settle(tester);
    expect(find.text('Start'), findsOneWidget);
    for (final label in ['Shut down', 'Restart', 'Force stop', 'Keyboard']) {
      expect(_opacityOf(tester, label), lessThan(1), reason: label);
    }
  });

  Future<void> toTrackpad(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('key-mode')));
    await _settle(tester);
  }

  testWidgets('toggle switches between keys and trackpad', (tester) async {
    await pump(tester, VmState.running);
    expect(find.byKey(const Key('key-left')), findsOneWidget);
    expect(find.byKey(const Key('trackpad')), findsNothing);
    await toTrackpad(tester);
    expect(find.byKey(const Key('trackpad')), findsOneWidget);
    expect(find.byKey(const Key('key-left')), findsNothing);
    expect(find.byKey(const Key('key-esc')), findsNothing);
    await tester.tap(find.byKey(const Key('key-mode')));
    await _settle(tester);
    expect(find.byKey(const Key('key-left')), findsOneWidget);
    expect(lastTrackpadMode, isFalse);
  });

  testWidgets('drag moves the pointer by the scaled delta and clamps', (
    tester,
  ) async {
    final display = await pump(tester, VmState.running);
    await toTrackpad(tester);
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('trackpad'))),
    );
    display.pointers.clear();
    await g.moveBy(const Offset(5, 3));
    // Centre (400, 300) plus gain 2 on (5, 3).
    expect(display.pointers.last, (410, 306, 0));
    await g.moveBy(const Offset(-1000, -1000));
    expect(display.pointers.last, (0, 0, 0));
    await g.moveBy(const Offset(5000, 5000));
    expect(display.pointers.last, (799, 599, 0));
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('tap sends left button down then up', (tester) async {
    final display = await pump(tester, VmState.running);
    await toTrackpad(tester);
    display.pointers.clear();
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('trackpad'))),
    );
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(display.pointers.map((p) => p.$3), [1, 0]);
  });

  testWidgets('right-click button sends the right button mask', (tester) async {
    final display = await pump(tester, VmState.running);
    await toTrackpad(tester);
    display.pointers.clear();
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('pad-right-click'))),
    );
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(display.pointers.map((p) => p.$3), [4, 0]);
  });

  group('fullscreen', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (c) async {
            calls.add(c);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<_FakeDisplay> enter(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final d = await pump(tester, VmState.running);
      await tester.tap(find.byKey(const Key('key-fullscreen')));
      await _settle(tester);
      return d;
    }

    bool hasOrientation(List<String> want) => calls.any(
      (c) =>
          c.method == 'SystemChrome.setPreferredOrientations' &&
          (c.arguments as List).length == want.length &&
          want.every((w) => (c.arguments as List).contains(w)),
    );

    bool hasMode(String mode) => calls.any(
      (c) =>
          c.method == 'SystemChrome.setEnabledSystemUIMode' &&
          c.arguments == mode,
    );

    testWidgets('entering locks landscape and shows the side panel', (
      tester,
    ) async {
      await enter(tester);
      expect(
        hasOrientation([
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
        isTrue,
      );
      expect(hasMode('SystemUiMode.immersiveSticky'), isTrue);
      expect(find.text('Alpha'), findsNothing, reason: 'app bar hidden');
      for (final k in [
        'key-esc',
        'key-up',
        'key-down',
        'key-left',
        'key-right',
        'key-enter',
        'key-mode',
        'key-more',
        'key-exit-fullscreen',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
    });

    testWidgets('keys and trackpad work in the side panel', (tester) async {
      final d = await enter(tester);
      d.keys.clear();
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('key-enter'))),
      );
      await g.up();
      await tester.pump();
      expect(d.keys, [(0xff0d, true), (0xff0d, false)]);

      await tester.tap(find.byKey(const Key('key-mode')));
      await _settle(tester);
      expect(find.byKey(const Key('trackpad')), findsOneWidget);
      final p = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('trackpad'))),
      );
      d.pointers.clear();
      await p.moveBy(const Offset(5, 3));
      expect(d.pointers.last, (410, 306, 0));
      await p.up();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('exit restores portrait and edge-to-edge', (tester) async {
      await enter(tester);
      calls.clear();
      await tester.tap(find.byKey(const Key('key-exit-fullscreen')));
      await _settle(tester);
      expect(hasOrientation(['DeviceOrientation.portraitUp']), isTrue);
      expect(hasMode('SystemUiMode.edgeToEdge'), isTrue);
      expect(find.byKey(const Key('key-fullscreen')), findsOneWidget);
    });
  });
}

double _opacityOf(WidgetTester tester, String label) => tester
    .widget<Opacity>(
      find.ancestor(of: find.text(label), matching: find.byType(Opacity)).first,
    )
    .opacity;
