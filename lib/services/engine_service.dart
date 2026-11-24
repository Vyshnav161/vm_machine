import 'dart:async';

import 'package:flutter/services.dart';

/// Event from `vm/events`.
sealed class EngineEvent {
  const EngineEvent();
}

class EngineStateChanged extends EngineEvent {
  final String id;

  /// `running`, `paused` or `stopping`.
  final String state;
  const EngineStateChanged(this.id, this.state);
}

class EngineQmpEvent extends EngineEvent {
  final String id;

  /// `SHUTDOWN`, `RESET`, `STOP` or `RESUME`.
  final String event;
  final Map<String, Object?> data;
  const EngineQmpEvent(this.id, this.event, this.data);
}

class EngineStartFailed extends EngineEvent {
  final String id;
  final String step;
  final String message;
  const EngineStartFailed(this.id, this.step, this.message);
}

/// Engine process ended. [crashed] is true for `crashed` events.
class EngineExit extends EngineEvent {
  final String id;
  final bool crashed;
  final int? exitCode;
  final int? signal;
  final String? signalName;

  /// `clean`, `killed`, `error` or `signal`.
  final String kind;
  final String message;
  const EngineExit({
    required this.id,
    required this.crashed,
    this.exitCode,
    this.signal,
    this.signalName,
    required this.kind,
    required this.message,
  });
}

class CopyProgressEvent extends EngineEvent {
  final String dest;
  final int copied;

  /// -1 when unknown.
  final int total;
  const CopyProgressEvent(this.dest, this.copied, this.total);
}

class MirrorChanged extends EngineEvent {
  final String? id;
  final bool mirroring;
  const MirrorChanged(this.id, this.mirroring);
}

/// Parses one `vm/events` map. Returns null for unknown shapes.
EngineEvent? parseEngineEvent(Object? raw) {
  if (raw is! Map) return null;
  final m = raw.cast<String, Object?>();
  final id = m['id'] as String?;
  switch (m['type']) {
    case 'stateChanged':
      if (id == null) return null;
      return EngineStateChanged(id, m['state'] as String? ?? '');
    case 'qmpEvent':
      if (id == null) return null;
      final d = m['data'];
      return EngineQmpEvent(
        id,
        m['event'] as String? ?? '',
        d is Map ? d.cast<String, Object?>() : const {},
      );
    case 'startFailed':
      if (id == null) return null;
      return EngineStartFailed(
        id,
        m['step'] as String? ?? 'qmp',
        m['message'] as String? ?? '',
      );
    case 'exited':
    case 'crashed':
      if (id == null) return null;
      return EngineExit(
        id: id,
        crashed: m['type'] == 'crashed',
        exitCode: (m['exitCode'] as num?)?.toInt(),
        signal: (m['signal'] as num?)?.toInt(),
        signalName: m['signalName'] as String?,
        kind: m['kind'] as String? ?? '',
        message: m['message'] as String? ?? '',
      );
    case 'copyProgress':
      return CopyProgressEvent(
        m['dest'] as String? ?? '',
        (m['copied'] as num?)?.toInt() ?? 0,
        (m['total'] as num?)?.toInt() ?? -1,
      );
    case 'mirrorChanged':
      return MirrorChanged(id, m['mirroring'] as bool? ?? false);
  }
  return null;
}

/// Arguments for `vm/engine` `start`.
class EngineStartRequest {
  final String id;
  final String name;
  final String executable;
  final List<String> args;
  final String qmpSocketPath;
  final String vncSocketPath;
  final String logPath;
  final String? vmDir;
  final int? vcpus;
  final double? cpuCap;
  const EngineStartRequest({
    required this.id,
    required this.name,
    required this.executable,
    required this.args,
    required this.qmpSocketPath,
    required this.vncSocketPath,
    required this.logPath,
    this.vmDir,
    this.vcpus,
    this.cpuCap,
  });

  Map<String, Object?> toArgs() => {
    'id': id,
    'name': name,
    'executable': executable,
    'args': args,
    'qmpSocketPath': qmpSocketPath,
    'vncSocketPath': vncSocketPath,
    'logPath': logPath,
    if (vmDir != null) 'vmDir': vmDir,
    if (vcpus != null) 'vcpus': vcpus,
    if (cpuCap != null) 'cpuCap': cpuCap,
  };
}

class EngineStats {
  final double? cpuPercent;
  final int? memBytes;
  const EngineStats({this.cpuPercent, this.memBytes});
}

/// Which QEMU binaries are present in the app's native library directory.
class EngineStatus {
  const EngineStatus(this.libs);

  static const qemuImgLib = 'libqemu-img.so';
  static const aarch64Lib = 'libqemu-system-aarch64.so';
  static const x86_64Lib = 'libqemu-system-x86_64.so';
  static const expectedLibs = [qemuImgLib, aarch64Lib, x86_64Lib];

  /// Library file name -> present.
  final Map<String, bool> libs;

  /// Nothing installed.
  const EngineStatus.none() : libs = const {};

  bool has(String lib) => libs[lib] ?? false;

  List<String> get missing => [
    for (final l in expectedLibs)
      if (!has(l)) l,
  ];

  bool get hasAnySystem => has(aarch64Lib) || has(x86_64Lib);

  /// `qemu-img` and at least one `qemu-system-*` binary are present.
  bool get installed => has(qemuImgLib) && hasAnySystem;

  /// Something is installed but not everything.
  bool get partial => !installed && libs.values.any((v) => v);

  factory EngineStatus.fromMap(Object? raw) {
    if (raw is! Map) return const EngineStatus.none();
    final l = raw['libs'];
    if (l is! Map) return const EngineStatus.none();
    return EngineStatus({
      for (final name in expectedLibs) name: l[name] == true,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is EngineStatus && other.missing.join() == missing.join();

  @override
  int get hashCode => Object.hashAll(missing);
}

/// Controls QEMU processes. Channels: `vm/engine` and `vm/events`.
/// Failures surface as [PlatformException] with the contract's codes
/// (`bad_args`, `not_running`, `engine_failed`, `qmp_failed`, `img_failed`,
/// `busy`, `engine_missing` (QEMU libraries not installed; `details` lists the
/// missing library names), ...).
abstract class EngineService {
  /// Broadcast stream of engine events (also carries copy and mirror events).
  Stream<EngineEvent> get events;

  /// Spawns the engine and returns its pid.
  Future<int> start(EngineStartRequest request);
  Future<void> pause(String id);
  Future<void> resume(String id);
  Future<void> powerdown(String id);
  Future<void> reset(String id);

  /// SIGKILL. True when the process is dead within 5 s.
  Future<bool> kill(String id);

  /// [disk] is required when the VM is not running.
  Future<void> snapshotCreate(String id, String name, {String? disk});
  Future<void> snapshotRestore(String id, String name, {String? disk});
  Future<void> snapshotDelete(String id, String name, {required String disk});

  /// Raw `qemu-img snapshot -l` output.
  Future<String> snapshotList(String disk);
  Future<EngineStats> stats(String id);
  Future<void> setCpuLimit(String id, int vcpus, double cap);

  /// qcow2, `preallocation=off`. Returns the qemu-img output.
  Future<String> createDisk(String path, int sizeBytes);

  /// `qemu-img info --output=json` output.
  Future<String> imageInfo(String path);

  /// VM dirs whose engine died with the app.
  Future<List<String>> recoverStale(List<String> vmDirs);
  Future<bool> isRunning(String id);

  /// Which QEMU libraries are installed.
  Future<EngineStatus> engineStatus();
}

class ChannelEngineService implements EngineService {
  final MethodChannel _channel;
  final EventChannel _events;
  Stream<EngineEvent>? _stream;

  ChannelEngineService({MethodChannel? channel, EventChannel? events})
    : _channel = channel ?? const MethodChannel('vm/engine'),
      _events = events ?? const EventChannel('vm/events');

  @override
  Stream<EngineEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map(parseEngineEvent)
      .where((e) => e != null)
      .cast<EngineEvent>()
      .asBroadcastStream();

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) =>
      _channel.invokeMethod<T>(method, args);

  @override
  Future<int> start(EngineStartRequest r) async {
    final m = await _channel.invokeMapMethod<String, Object?>(
      'start',
      r.toArgs(),
    );
    return (m!['pid']! as num).toInt();
  }

  @override
  Future<void> pause(String id) => _call('pause', {'id': id});
  @override
  Future<void> resume(String id) => _call('resume', {'id': id});
  @override
  Future<void> powerdown(String id) => _call('powerdown', {'id': id});
  @override
  Future<void> reset(String id) => _call('reset', {'id': id});

  @override
  Future<bool> kill(String id) async =>
      (await _call<bool>('kill', {'id': id})) ?? false;

  @override
  Future<void> snapshotCreate(String id, String name, {String? disk}) =>
      _call('snapshotCreate', {'id': id, 'name': name, 'disk': ?disk});

  @override
  Future<void> snapshotRestore(String id, String name, {String? disk}) =>
      _call('snapshotRestore', {'id': id, 'name': name, 'disk': ?disk});

  @override
  Future<void> snapshotDelete(String id, String name, {required String disk}) =>
      _call('snapshotDelete', {'id': id, 'name': name, 'disk': disk});

  @override
  Future<String> snapshotList(String disk) async =>
      (await _call<String>('snapshotList', {'disk': disk})) ?? '';

  @override
  Future<EngineStats> stats(String id) async {
    final m = await _channel.invokeMapMethod<String, Object?>('stats', {
      'id': id,
    });
    return EngineStats(
      cpuPercent: (m?['cpuPercent'] as num?)?.toDouble(),
      memBytes: (m?['memBytes'] as num?)?.toInt(),
    );
  }

  @override
  Future<void> setCpuLimit(String id, int vcpus, double cap) =>
      _call('setCpuLimit', {'id': id, 'vcpus': vcpus, 'cap': cap});

  @override
  Future<String> createDisk(String path, int sizeBytes) async =>
      (await _call<String>('createDisk', {
        'path': path,
        'sizeBytes': sizeBytes,
      })) ??
      '';

  @override
  Future<String> imageInfo(String path) async =>
      (await _call<String>('imageInfo', {'path': path})) ?? '';

  @override
  Future<List<String>> recoverStale(List<String> vmDirs) async =>
      (await _call<List<Object?>>('recoverStale', {
        'vmDirs': vmDirs,
      }))?.cast<String>() ??
      const [];

  @override
  Future<bool> isRunning(String id) async =>
      (await _call<bool>('isRunning', {'id': id})) ?? false;

  @override
  Future<EngineStatus> engineStatus() async => EngineStatus.fromMap(
    await _channel.invokeMapMethod<String, Object?>('engineStatus'),
  );
}
