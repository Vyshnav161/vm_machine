import 'package:glados/glados.dart';
import 'package:vm_machine/domain/vm_state_machine.dart';
import 'package:vm_machine/domain/enums.dart';

void main() {
  group('VmStateMachine', () {
    test('start, ready, pause, resume, shutdown, clean exit', () {
      var s = VmState.poweredOff;
      for (final (e, expected) in <(VmEvent, VmState)>[
        (const Start(), VmState.starting),
        (const EngineReady(), VmState.running),
        (const Pause(), VmState.paused),
        (const Resume(), VmState.running),
        (const Shutdown(), VmState.stopping),
        (const EngineExited(code: 0), VmState.poweredOff),
      ]) {
        final t = VmStateMachine.apply(s, e);
        expect(t.accepted, isTrue);
        expect(t.next, expected);
        s = t.next;
      }
    });

    test('restart goes through starting and returns via engineReady', () {
      final t = VmStateMachine.apply(VmState.running, const Restart());
      expect(t.next, VmState.starting);
      expect(
        VmStateMachine.apply(t.next, const EngineReady()).next,
        VmState.running,
      );
    });

    test('illegal event is rejected and state unchanged', () {
      final t = VmStateMachine.apply(VmState.poweredOff, const Pause());
      expect(t.accepted, isFalse);
      expect(t.next, VmState.poweredOff);
    });

    test('crash from active states yields error with reason', () {
      for (final s in [
        VmState.starting,
        VmState.running,
        VmState.paused,
        VmState.stopping,
      ]) {
        final t = VmStateMachine.apply(s, const EngineCrashed('SIGSEGV'));
        expect(t.next, VmState.error);
        expect(t.errorReason, 'SIGSEGV');
        expect(t.accepted, isTrue);
      }
    });

    test('NetworkChanged never changes state', () {
      for (final s in VmState.values) {
        final t = VmStateMachine.apply(
          s,
          const NetworkChanged(connected: false),
        );
        expect(t.next, s);
      }
    });

    test('error can be acknowledged or restarted', () {
      expect(
        VmStateMachine.apply(VmState.error, const Acknowledge()).next,
        VmState.poweredOff,
      );
      expect(
        VmStateMachine.apply(VmState.error, const Start()).next,
        VmState.starting,
      );
    });
  });
}
