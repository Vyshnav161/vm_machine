import 'enums.dart';

/// Events that drive the VM lifecycle (design: VmStateMachine).
sealed class VmEvent {
  const VmEvent();
}

class Start extends VmEvent {
  const Start();
}

class EngineReady extends VmEvent {
  const EngineReady();
}

class Pause extends VmEvent {
  const Pause();
}

class Resume extends VmEvent {
  const Resume();
}

class Shutdown extends VmEvent {
  const Shutdown();
}

class ForceStop extends VmEvent {
  const ForceStop();
}

class Restart extends VmEvent {
  const Restart();
}

class GuestPoweredOff extends VmEvent {
  const GuestPoweredOff();
}

/// The engine process ended. An exit code of 0 is a clean exit.
class EngineExited extends VmEvent {
  const EngineExited({required this.code, this.reason});
  final int code;
  final String? reason;

  bool get clean => code == 0;
}

class EngineCrashed extends VmEvent {
  const EngineCrashed(this.reason);
  final String reason;
}

class Acknowledge extends VmEvent {
  const Acknowledge();
}

/// Host network connectivity changed. Never changes the VM state.
class NetworkChanged extends VmEvent {
  const NetworkChanged({required this.connected});
  final bool connected;
}

/// Result of applying an event to a state.
class VmTransition {
  const VmTransition({
    required this.next,
    this.errorReason,
    required this.accepted,
  });

  final VmState next;
  final String? errorReason;
  final bool accepted;

  @override
  bool operator ==(Object other) =>
      other is VmTransition &&
      other.next == next &&
      other.errorReason == errorReason &&
      other.accepted == accepted;

  @override
  int get hashCode => Object.hash(next, errorReason, accepted);

  @override
  String toString() =>
      'VmTransition(next: $next, errorReason: $errorReason, accepted: $accepted)';
}

/// Pure lifecycle transition table.
abstract final class VmStateMachine {
  static VmTransition apply(VmState state, VmEvent event) {
    VmTransition go(VmState next) => VmTransition(next: next, accepted: true);
    VmTransition fail(String reason) =>
        VmTransition(next: VmState.error, errorReason: reason, accepted: true);
    VmTransition reject() => VmTransition(next: state, accepted: false);

    // Network changes are accepted in every state and never move it.
    if (event is NetworkChanged) return go(state);

    // Crashes from any active state end in Error with the reason.
    if (event is EngineCrashed) {
      switch (state) {
        case VmState.starting:
        case VmState.running:
        case VmState.paused:
        case VmState.stopping:
          return fail(event.reason);
        case VmState.poweredOff:
        case VmState.error:
          return reject();
      }
    }

    switch (state) {
      case VmState.poweredOff:
        if (event is Start) return go(VmState.starting);
        return reject();
      case VmState.starting:
        if (event is EngineReady) return go(VmState.running);
        if (event is EngineExited) {
          return fail(event.reason ?? 'Engine exited with code ${event.code}');
        }
        return reject();
      case VmState.running:
        if (event is Pause) return go(VmState.paused);
        if (event is Shutdown || event is ForceStop) {
          return go(VmState.stopping);
        }
        if (event is Restart) return go(VmState.starting);
        if (event is GuestPoweredOff) return go(VmState.poweredOff);
        if (event is EngineExited) {
          // Not in the design table: an exit while running is unexpected.
          return fail(
            event.reason ?? 'Engine exited unexpectedly (${event.code})',
          );
        }
        return reject();
      case VmState.paused:
        if (event is Resume) return go(VmState.running);
        if (event is Shutdown || event is ForceStop) {
          return go(VmState.stopping);
        }
        if (event is EngineExited) {
          return fail(
            event.reason ?? 'Engine exited unexpectedly (${event.code})',
          );
        }
        return reject();
      case VmState.stopping:
        if (event is EngineExited) {
          return event.clean
              ? go(VmState.poweredOff)
              : fail(event.reason ?? 'Engine exited with code ${event.code}');
        }
        return reject();
      case VmState.error:
        if (event is Start) return go(VmState.starting);
        if (event is Acknowledge) return go(VmState.poweredOff);
        return reject();
    }
  }
}
