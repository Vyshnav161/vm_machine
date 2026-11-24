import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vm_machine/services/services.dart';

/// In-memory engine. Records QMP-backed commands (`stop`, `cont`,
/// `system_powerdown`, `system_reset`, `savevm`, `loadvm`) in [qmpCommands],
/// and process-level calls (`kill`, `start`, ...) in [calls].
class FakeEngineService implements EngineService {
  final _events = StreamController<EngineEvent>.broadcast();
  final List<String> qmpCommands = [];
  final List<String> calls = [];
  final List<EngineStartRequest> started = [];
  final Set<String> running = {};

  /// Disk path -> snapshot names, for not-running snapshot operations.
  final Map<String, List<String>> diskSnapshots = {};

  /// Disk path -> size, as created by [createDisk].
  final Map<String, int> disks = {};

  /// Method names that throw [PlatformException] (code `engine_failed`).
  final Set<String> failingMethods = {};
  String failureCode = 'engine_failed';

  /// Result of [engineStatus]. Defaults to fully installed.
  EngineStatus engineStatusResult = const EngineStatus({
    EngineStatus.qemuImgLib: true,
    EngineStatus.aarch64Lib: true,
    EngineStatus.x86_64Lib: true,
  });
  bool killSucceeds = true;
  int nextPid = 1000;
  EngineStats statsResult = const EngineStats(cpuPercent: 0, memBytes: 0);
  String imageInfoResult = '{}';
  List<String> staleDirs = const [];

  void failOn(String method, {String code = 'engine_failed'}) {
    failingMethods.add(method);
    failureCode = code;
  }

  void clearFailures() => failingMethods.clear();

  void emit(EngineEvent e) => _events.add(e);

  void _check(String method) {
    calls.add(method);
    if (failingMethods.contains(method)) {
      throw PlatformException(
        code: failureCode,
        message: '$method failed',
        details: failureCode == 'engine_missing'
            ? engineStatusResult.missing
            : null,
      );
    }
  }

  void _qmp(String method, String command, String id) {
    _check(method);
    if (!running.contains(id)) {
      throw PlatformException(code: 'not_running', message: 'not running');
    }
    qmpCommands.add(command);
  }

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<int> start(EngineStartRequest request) async {
    _check('start');
    started.add(request);
    running.add(request.id);
    return nextPid++;
  }

  @override
  Future<void> pause(String id) async => _qmp('pause', 'stop', id);
  @override
  Future<void> resume(String id) async => _qmp('resume', 'cont', id);
  @override
  Future<void> powerdown(String id) async =>
      _qmp('powerdown', 'system_powerdown', id);
  @override
  Future<void> reset(String id) async => _qmp('reset', 'system_reset', id);

  @override
  Future<bool> kill(String id) async {
    _check('kill');
    if (killSucceeds) running.remove(id);
    return killSucceeds;
  }

  @override
  Future<void> snapshotCreate(String id, String name, {String? disk}) async {
    _check('snapshotCreate');
    if (running.contains(id)) {
      qmpCommands.add('savevm');
    } else {
      if (disk == null) {
        throw PlatformException(code: 'bad_args', message: 'disk');
      }
      diskSnapshots.putIfAbsent(disk, () => []).add(name);
    }
  }

  @override
  Future<void> snapshotRestore(String id, String name, {String? disk}) async {
    _check('snapshotRestore');
    if (running.contains(id)) {
      qmpCommands.add('loadvm');
    } else if (disk == null ||
        !(diskSnapshots[disk]?.contains(name) ?? false)) {
      throw PlatformException(code: 'img_failed', message: 'no snapshot');
    }
  }

  @override
  Future<void> snapshotDelete(
    String id,
    String name, {
    required String disk,
  }) async {
    _check('snapshotDelete');
    if (running.contains(id)) {
      throw PlatformException(code: 'busy', message: 'busy');
    }
    diskSnapshots[disk]?.remove(name);
  }

  @override
  Future<String> snapshotList(String disk) async {
    _check('snapshotList');
    return [
      'Snapshot list:',
      'ID        TAG               VM SIZE                DATE       VM CLOCK',
      for (final (i, n) in (diskSnapshots[disk] ?? const <String>[]).indexed)
        '${i + 1}         $n  0 B 2025-01-01 00:00:00 00:00:00.000',
    ].join('\n');
  }

  @override
  Future<EngineStats> stats(String id) async {
    _check('stats');
    return statsResult;
  }

  @override
  Future<void> setCpuLimit(String id, int vcpus, double cap) async =>
      _check('setCpuLimit');

  @override
  Future<String> createDisk(String path, int sizeBytes) async {
    _check('createDisk');
    disks[path] = sizeBytes;
    return 'Formatting $path, fmt=qcow2 size=$sizeBytes preallocation=off';
  }

  @override
  Future<String> imageInfo(String path) async {
    _check('imageInfo');
    return imageInfoResult;
  }

  @override
  Future<List<String>> recoverStale(List<String> vmDirs) async {
    _check('recoverStale');
    return staleDirs;
  }

  @override
  Future<bool> isRunning(String id) async => running.contains(id);

  @override
  Future<EngineStatus> engineStatus() async {
    _check('engineStatus');
    return engineStatusResult;
  }

  Future<void> dispose() => _events.close();
}
