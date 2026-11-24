import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/profile_serializer.dart';
import '../data/vm_repository.dart';
import '../domain/domain.dart';
import '../services/services.dart';
import 'file_ops.dart';
import 'vm_layout.dart';

/// Runtime (non-persisted) data for one VM.
class VmRuntime {
  const VmRuntime({
    this.state = VmState.poweredOff,
    this.errorReason,
    this.lastFailure,
    this.failureMessage,
    this.networkConnected = true,
  });

  final VmState state;

  /// Exit reason when [state] is [VmState.error].
  final String? errorReason;

  /// Most recent failed start, kept until the next start attempt.
  final StartFailure? lastFailure;

  /// [FailureMessage.format] output for [lastFailure].
  final String? failureMessage;

  /// Guest network link flag. Changing it never changes [state] (Req 11.4).
  final bool networkConnected;

  VmRuntime copyWith({
    VmState? state,
    String? errorReason,
    bool clearErrorReason = false,
    StartFailure? lastFailure,
    String? failureMessage,
    bool clearFailure = false,
    bool? networkConnected,
  }) => VmRuntime(
    state: state ?? this.state,
    errorReason: clearErrorReason ? null : errorReason ?? this.errorReason,
    lastFailure: clearFailure ? null : lastFailure ?? this.lastFailure,
    failureMessage: clearFailure ? null : failureMessage ?? this.failureMessage,
    networkConnected: networkConnected ?? this.networkConnected,
  );
}

/// Outcome of a controller command.
class CommandResult {
  const CommandResult.ok() : this._(true, null, null);

  /// Success that produced or changed [profile].
  const CommandResult.okWith(VmProfile profile)
    : this._(true, null, null, profile: profile);
  const CommandResult.rejected(String reason) : this._(false, reason, null);
  const CommandResult.failed(StartFailure failure, String message)
    : this._(false, message, failure);

  /// Rejected by [ProfileValidator]; [issues] is never empty.
  CommandResult.invalid(List<ValidationIssue> issues)
    : this._(
        false,
        issues.map((i) => i.message).join('\n'),
        null,
        issues: issues,
      );
  const CommandResult._(
    this.ok,
    this.message,
    this.failure, {
    this.profile,
    this.issues = const [],
  });

  final bool ok;

  /// User-facing text when [ok] is false.
  final String? message;

  /// Set when the command failed at a named step.
  final StartFailure? failure;

  /// The created, edited, cloned or imported profile.
  final VmProfile? profile;

  /// Validation issues when a create or edit was rejected.
  final List<ValidationIssue> issues;

  @override
  String toString() => ok ? 'CommandResult.ok' : 'CommandResult($message)';
}

/// Copy progress for one destination file (Req 4.3).
class MediaCopyProgress {
  const MediaCopyProgress(this.dest, this.percent);
  final String dest;

  /// 0..100.
  final int percent;
}

/// Why [VmManagerController.prepareMedia] rejected a file.
enum MediaProblem {
  /// All-files access is not granted; in-place media cannot be opened.
  allFilesAccess,

  /// The picked URI cannot be mapped to a real file path.
  unresolvable,

  /// Any other reason; the message says which.
  other,
}

/// Result of [VmManagerController.prepareMedia].
class MediaPrep {
  const MediaPrep.ready(MediaRef this.media) : message = null, problem = null;
  const MediaPrep.rejected(
    String this.message, {
    this.problem = MediaProblem.other,
  }) : media = null;
  final MediaRef? media;
  final String? message;
  final MediaProblem? problem;
  bool get ok => media != null;

  /// True when copying into app storage would avoid the problem.
  bool get copyWouldHelp =>
      problem == MediaProblem.allFilesAccess ||
      problem == MediaProblem.unresolvable;
}

/// Kind of user-facing notice raised by the resource policy.
enum HostNoticeKind { thermalPause, batteryLow, lowStorage }

/// Notice for the UI or the Android notification layer (Req 7.4, 7.5, 8.6).
class HostNotice {
  const HostNotice(this.kind, this.message, this.vmIds);
  final HostNoticeKind kind;
  final String message;

  /// Running VMs the notice is about. For [HostNoticeKind.batteryLow] the UI
  /// offers to pause or shut these down (Req 7.5).
  final List<String> vmIds;
}

/// One sample of guest resource use (Req 7.2).
class VmStats {
  const VmStats({
    required this.cpuPercent,
    required this.memBytes,
    required this.mode,
    required this.crossArch,
  });
  final double cpuPercent;
  final int memBytes;
  final AccelerationMode mode;

  /// Whether the cross-architecture indicator applies (Req 7.3).
  final bool crossArch;

  String get text => StatsOverlay.format(cpuPercent, memBytes, mode);
}

/// Joins pure logic, repository and platform services (design: layering
/// rules). The UI calls this class and listens to [changes].
///
/// Sections: lifecycle (here), library and media (task 9.3), snapshots,
/// host signals and diagnostics (task 9.4). Later sections reuse
/// [profiles], [runtimeOf], [_setRuntime] and [_applyEvent].
class VmManagerController {
  VmManagerController({
    required this.repository,
    required this.engine,
    required this.files,
    required this.hostProbe,
    required this.layout,
    required this.pathExists,
    this.fileOps = const IoFileOps(),
    HostSignalService? hostSignals,
    this.logMaxBytes = LogRotator.defaultMaxBytes,
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now {
    _engineSub = engine.events.listen(_onEngineEvent);
    _signalSub = hostSignals?.signals.listen(
      (s) => _signalChain = _signalChain.then((_) => handleHostSignals(s)),
    );
  }

  final VmRepository repository;
  final EngineService engine;
  final FileService files;
  final HostProbeService hostProbe;
  final VmLayout layout;

  /// Whether a path exists. `content://` URIs are checked through
  /// [FileService.resolveRealPath] instead.
  final Future<bool> Function(String path) pathExists;

  /// Delete, copy and mkdir for library operations.
  final FileOps fileOps;

  /// Log files above this size are cut to their newest bytes (Req 12.5).
  final int logMaxBytes;
  final String Function() _newId;
  final DateTime Function() _now;

  final Map<String, VmProfile> _profiles = {};
  final Map<String, VmRuntime> _runtime = {};
  final Set<String> _forceStopping = {};

  final _changes = StreamController<void>.broadcast();
  final _copyProgress = StreamController<MediaCopyProgress>.broadcast();
  final _notices = StreamController<HostNotice>.broadcast();
  StreamSubscription<EngineEvent>? _engineSub;
  StreamSubscription<HostSignals>? _signalSub;
  Future<void> _signalChain = Future.value();
  HostCapabilities? _host;

  /// Fires after any profile or runtime change.
  Stream<void> get changes => _changes.stream;

  List<VmProfile> get profiles => List.unmodifiable(_profiles.values);

  VmProfile? profileOf(String id) => _profiles[id];

  VmRuntime runtimeOf(String id) => _runtime[id] ?? const VmRuntime();

  VmState stateOf(String id) => runtimeOf(id).state;

  /// Last probed host capabilities, if any.
  HostCapabilities? get host => _host;

  /// Percent progress of media copies (Req 4.3).
  Stream<MediaCopyProgress> get copyProgress => _copyProgress.stream;

  /// Notices raised by host-signal handling.
  Stream<HostNotice> get notices => _notices.stream;

  Future<void> dispose() async {
    await _engineSub?.cancel();
    await _signalSub?.cancel();
    await _signalChain;
    await _notices.close();
    await _changes.close();
    await _copyProgress.close();
  }

  /// Loads profiles from the repository. Existing runtime state is kept.
  Future<void> load() async {
    _profiles
      ..clear()
      ..addEntries([
        for (final pr in await repository.loadAll()) MapEntry(pr.id, pr),
      ]);
    _notify();
  }

  /// After an app restart, asks the engine which VMs died with the app and
  /// marks them `Error` without touching their disks (Req 5.8). Returns the
  /// affected VM ids.
  Future<List<String>> reconcileStaleRuntime() async {
    final dirs = {for (final id in _profiles.keys) layout.vmDir(id): id};
    if (dirs.isEmpty) return const [];
    List<String> stale;
    try {
      stale = await engine.recoverStale(dirs.keys.toList());
    } on PlatformException {
      return const [];
    }
    final ids = <String>[];
    for (final dir in stale) {
      final id = dirs[dir] ?? dirs[dir.replaceAll(RegExp(r'/+$'), '')];
      if (id == null) continue;
      ids.add(id);
      _runtime[id] = const VmRuntime().copyWith(
        state: VmState.error,
        errorReason: 'The app was closed while this VM was running.',
      );
    }
    if (ids.isNotEmpty) _notify();
    return ids;
  }

  // ---------------------------------------------------------------------
  // Internal helpers shared by all sections.
  // ---------------------------------------------------------------------

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _setRuntime(String id, VmRuntime r) {
    _runtime[id] = r;
    _notify();
  }

  /// Runs [event] through the state machine and stores the result.
  /// Returns whether the event was accepted.
  bool _applyEvent(String id, VmEvent event) {
    final cur = runtimeOf(id);
    final t = VmStateMachine.apply(cur.state, event);
    if (!t.accepted) return false;
    final next = switch (t.next) {
      VmState.error => cur.copyWith(
        state: VmState.error,
        errorReason: t.errorReason,
      ),
      _ => cur.copyWith(state: t.next, clearErrorReason: true),
    };
    _setRuntime(id, next);
    return true;
  }

  Future<HostCapabilities> _ensureHost() async {
    final known = _host;
    if (known != null) return known;
    try {
      return _host = await hostProbe.probe();
    } on PlatformException {
      // Unreadable host data stays Unknown and never blocks (Req 1.7).
      return const HostCapabilities();
    }
  }

  bool _isActive(VmState s) =>
      s == VmState.starting ||
      s == VmState.running ||
      s == VmState.paused ||
      s == VmState.stopping;

  /// Maps a platform error to a [StartFailure]; `engine_missing` becomes the
  /// typed engine-not-installed failure.
  StartFailure _failureFor(String step, Object e) {
    if (e is PlatformException && e.code == 'engine_missing') {
      final d = e.details;
      return StartFailure.engineMissing(
        d is List ? d.cast<String>() : const [],
      );
    }
    return StartFailure(step, _describe(e));
  }

  /// Which QEMU libraries are installed. Reports none when the check fails.
  Future<EngineStatus> engineStatus() async {
    try {
      return await engine.engineStatus();
    } on PlatformException {
      return const EngineStatus.none();
    }
  }

  String _describe(Object e) =>
      e is PlatformException ? (e.message ?? e.code) : e.toString();

  // ---------------------------------------------------------------------
  // Start (Req 2.7, 4.5, 5.1, 5.9, 12.1, 12.6)
  // ---------------------------------------------------------------------

  /// Start sequence: eligibility, media preflight, launch spec, engine.
  /// A failure before the engine call leaves the state unchanged.
  Future<CommandResult> start(String id) async {
    final profile = _profiles[id];
    if (profile == null) {
      return const CommandResult.rejected('Unknown VM.');
    }
    final cur = runtimeOf(id);
    if (cur.state != VmState.poweredOff && cur.state != VmState.error) {
      return CommandResult.rejected(
        'Cannot start a VM that is ${cur.state.name}.',
      );
    }

    final host = await _ensureHost();
    final crossArch = _crossArch(profile, host);
    CommandResult fail(String step, String cause) =>
        _recordFailure(id, StartFailure(step, cause), crossArch);

    // 1. Eligibility.
    final running = [
      for (final e in _profiles.entries)
        if (e.key != id && _isActive(stateOf(e.key))) e.value,
    ];
    final decision = StartEligibility.check(
      profile: profile,
      report: CompatibilityEvaluator.evaluate(host),
      runningVms: running,
      hostRamBytes: host.totalRamBytes,
    );
    if (decision is StartBlocked) {
      return fail('eligibility', decision.reason);
    }

    // 2. Media preflight. QEMU opens files by real path. Profiles saved by
    // older builds may hold `content://` references; those are mapped to a
    // real path here when possible.
    final launchPaths = <String, String>{};
    for (final d in profile.disks) {
      final r = await _launchPath(d.path);
      if (r != null) launchPaths[d.path] = r;
    }
    for (final m in profile.media) {
      final r = await _launchPath(m.path);
      if (r != null) launchPaths[m.path] = r;
    }
    final missing = MediaPreflight.missing(profile, launchPaths.containsKey);
    if (missing.isNotEmpty) {
      return fail('media', await _missingMediaCause(missing));
    }

    // 3. Launch spec, built from the resolved real paths. The stored
    // profile keeps the original references.
    final LaunchSpec spec;
    try {
      spec = LaunchSpecBuilder.build(
        profile.copyWith(
          disks: [
            for (final d in profile.disks)
              d.copyWith(path: launchPaths[d.path]),
          ],
          media: [
            for (final m in profile.media)
              m.copyWith(path: launchPaths[m.path]),
          ],
        ),
        host,
        layout.pathsFor(id),
      );
    } on Object catch (e) {
      return fail('launch', _describe(e));
    }

    // 4. Engine. The state machine moves to Starting only now.
    _applyEvent(id, const Start());
    _setRuntime(id, runtimeOf(id).copyWith(clearFailure: true));
    try {
      await engine.start(
        EngineStartRequest(
          id: id,
          name: profile.name,
          executable: spec.executable,
          args: spec.args,
          qmpSocketPath: spec.qmpSocketPath,
          vncSocketPath: spec.vncSocketPath,
          logPath: spec.logPath,
          vmDir: layout.vmDir(id),
          vcpus: profile.cpuCount,
          cpuCap: profile.batterySaver
              ? BatterySaver.effectiveCpuCap(profile.cpuCount, true)
              : null,
        ),
      );
    } on Object catch (e) {
      final f = _failureFor('engine', e);
      _applyEvent(id, EngineCrashed(f.cause));
      return _recordFailure(id, f, crossArch);
    }
    return const CommandResult.ok();
  }

  /// The path QEMU should open for [path], or null when it is unreadable.
  /// A `content://` URI is mapped to a real file path; QEMU cannot open
  /// descriptors that belong to the app process.
  Future<String?> _launchPath(String path) async {
    if (!path.startsWith('content://')) {
      return await pathExists(path) ? path : null;
    }
    try {
      return await files.resolveRealPath(path);
    } on PlatformException {
      return null;
    }
  }

  /// Explains why [missing] files cannot be opened. `content://` entries
  /// get a specific hint about All-files access or re-attaching.
  Future<String> _missingMediaCause(List<String> missing) async {
    final base = 'Missing files: ${missing.join(', ')}';
    if (!missing.any((m) => m.startsWith('content://'))) return base;
    var access = true;
    try {
      access = await files.hasAllFilesAccess();
    } on PlatformException {
      // Unknown; fall through to the generic hint.
    }
    return access
        ? '$base. A content:// reference could not be resolved to a file. '
              'Detach the media and attach it again, or copy it into app '
              'storage.'
        : '$base. A content:// reference needs All-files access to be '
              'opened. Grant All-files access in the media screen, or detach '
              'the media and copy it into app storage.';
  }

  /// Existence check that holds nothing open.
  Future<bool> _exists(String path) async {
    if (!path.startsWith('content://')) return pathExists(path);
    try {
      return await files.resolveRealPath(path) != null;
    } on PlatformException {
      return false;
    }
  }

  /// Whether All-files access is granted (false when it cannot be read).
  Future<bool> hasAllFilesAccess() async {
    try {
      return await files.hasAllFilesAccess();
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system All-files access screen.
  Future<bool> requestAllFilesAccess() async {
    try {
      return await files.requestAllFilesAccess();
    } on PlatformException {
      return false;
    }
  }

  bool _crossArch(VmProfile p, HostCapabilities host) {
    final hostArch = host.arch.valueOrNull;
    if (hostArch == null) return false;
    return CrossArchIndicator.isActive(
      hostArch,
      p.guestArch,
      LaunchSpecBuilder.accelerationFor(p, host),
    );
  }

  CommandResult _recordFailure(String id, StartFailure f, bool crossArch) {
    final p = _profiles[id];
    final msg = FailureMessage.format(
      f,
      crossArch: crossArch,
      archHint: p == null
          ? null
          : ArchMismatchDetector.hint(p.media, p.guestArch),
    );
    _setRuntime(
      id,
      runtimeOf(id).copyWith(lastFailure: f, failureMessage: msg),
    );
    return CommandResult.failed(f, msg);
  }

  // ---------------------------------------------------------------------
  // Pause, resume, shutdown, restart, force stop (Req 5.2 to 5.6)
  // ---------------------------------------------------------------------

  Future<CommandResult> pause(String id) =>
      _command(id, const Pause(), 'pause', () => engine.pause(id));

  Future<CommandResult> resume(String id) =>
      _command(id, const Resume(), 'resume', () => engine.resume(id));

  /// ACPI power-off through `system_powerdown`.
  Future<CommandResult> shutdown(String id) =>
      _command(id, const Shutdown(), 'shutdown', () => engine.powerdown(id));

  /// `system_reset`. The state returns to Running on the guest reset event.
  Future<CommandResult> restart(String id) =>
      _command(id, const Restart(), 'restart', () => engine.reset(id));

  /// Kills the process without any QMP command. The caller must pass
  /// `confirmed: true` after asking the user (Req 5.5).
  Future<CommandResult> forceStop(String id, {required bool confirmed}) async {
    if (!confirmed) {
      return const CommandResult.rejected('Force stop needs confirmation.');
    }
    final cur = runtimeOf(id).state;
    if (!VmStateMachine.apply(cur, const ForceStop()).accepted) {
      return CommandResult.rejected('Cannot force stop a ${cur.name} VM.');
    }
    _forceStopping.add(id);
    _applyEvent(id, const ForceStop());
    final bool dead;
    try {
      dead = await engine.kill(id);
    } on Object catch (e) {
      _forceStopping.remove(id);
      _applyEvent(id, EngineCrashed(_describe(e)));
      return CommandResult.failed(
        StartFailure('force stop', _describe(e)),
        _describe(e),
      );
    }
    _forceStopping.remove(id);
    if (!dead) {
      const reason = 'Process did not exit within 5 seconds.';
      _applyEvent(id, const EngineCrashed(reason));
      return const CommandResult.failed(
        StartFailure('force stop', reason),
        reason,
      );
    }
    // The exit event may have arrived first; then this is rejected.
    _applyEvent(id, const EngineExited(code: 0));
    return const CommandResult.ok();
  }

  /// Applies [event] before running [action], so an engine event that
  /// arrives during the call (for example RESET) lands on the new state.
  /// The previous runtime is restored when the action throws.
  Future<CommandResult> _command(
    String id,
    VmEvent event,
    String step,
    Future<void> Function() action,
  ) async {
    final before = runtimeOf(id);
    if (!_applyEvent(id, event)) {
      return CommandResult.rejected('Cannot $step a ${before.state.name} VM.');
    }
    try {
      await action();
    } on Object catch (e) {
      _setRuntime(id, before);
      return CommandResult.failed(
        StartFailure(step, _describe(e)),
        _describe(e),
      );
    }
    return const CommandResult.ok();
  }

  // ---------------------------------------------------------------------
  // Compatibility detection (Req 1.1, 1.6, 1.7)
  // ---------------------------------------------------------------------

  /// The report for the last probed host, or null before the first probe.
  CompatibilityReport? get report {
    final h = _host;
    return h == null ? null : CompatibilityEvaluator.evaluate(h);
  }

  /// Probes on first use and returns the cached result afterwards. Values
  /// that cannot be read stay `Unknown` and never block (Req 1.7).
  Future<CompatibilityReport> detectCapabilities() async =>
      CompatibilityEvaluator.evaluate(await _ensureHost());

  /// Repeats detection (Req 1.6). A probe that fails or takes longer than
  /// 5 seconds keeps the previous values.
  Future<CompatibilityReport> refreshCapabilities() async {
    try {
      _host = await hostProbe.probe().timeout(const Duration(seconds: 5));
    } on PlatformException {
      // Keep the previous values.
    } on TimeoutException {
      // Keep the previous values.
    }
    _notify();
    return CompatibilityEvaluator.evaluate(_host ?? const HostCapabilities());
  }

  // ---------------------------------------------------------------------
  // Library: create, edit, delete, clone, search, export, import
  // (Req 3.3, 3.8, 3.9, 8.1, 8.3, 8.4, 8.5, 10.1, 10.4 to 10.7, 10.9)
  // ---------------------------------------------------------------------

  /// New VM id for callers that need it before [create] (for example to
  /// copy media into the VM's media folder first).
  String newVmId() => _newId();

  /// Profiles whose name contains [query], ignoring case (Req 10.3).
  List<VmProfile> search(String query) => LibrarySearch.filter(profiles, query);

  /// Removable volumes the disk can be placed on (Req 8.5). Empty when the
  /// device has none; the UI offers the option only when this is non-empty.
  Future<List<RemovableVolume>> removableVolumes() async {
    try {
      return await files.removableVolumes();
    } on PlatformException {
      return const [];
    }
  }

  /// Validates [draft] with the rules shared by create and edit (Req 3.8).
  /// [editingId] excludes that profile's own name from the uniqueness check.
  Future<List<ValidationIssue>> validate(
    ProfileDraft draft, {
    String? editingId,
    RemovableVolume? volume,
  }) async {
    final host = _hostForDisk(await _ensureHost(), volume);
    return ProfileValidator.validate(
      draft: draft,
      existingNames: [
        for (final e in _profiles.entries)
          if (e.key != editingId) e.value.name,
      ],
      host: host,
    );
  }

  /// The free storage that applies to the chosen disk location.
  HostCapabilities _hostForDisk(HostCapabilities host, RemovableVolume? v) {
    final free = v?.freeBytes;
    return free == null ? host : host.copyWith(freeStorageBytes: Known(free));
  }

  /// Validates, creates the qcow2 disk, then saves the profile (Req 3.3).
  /// [id] must come from [newVmId] when media was copied for this VM first.
  /// [volume] places the disk on removable storage (Req 8.5). On any
  /// failure nothing is added to the library and a created disk is removed.
  Future<CommandResult> create(
    ProfileDraft draft, {
    String? id,
    RemovableVolume? volume,
  }) async {
    final issues = await validate(draft, volume: volume);
    if (issues.isNotEmpty) return CommandResult.invalid(issues);

    final vmId = id ?? _newId();
    if (_profiles.containsKey(vmId)) {
      return const CommandResult.rejected('A VM with this id already exists.');
    }
    final diskDir = volume == null
        ? layout.disksDir(vmId)
        : p.join(volume.path, vmId);
    final diskPath = p.join(diskDir, 'disk0.qcow2');
    try {
      await fileOps.ensureDir(diskDir);
      await engine.createDisk(diskPath, draft.diskBytes);
    } on Object catch (e) {
      await _quietDelete(diskPath);
      final f = _failureFor('create disk', e);
      return CommandResult.failed(
        f,
        f.isEngineMissing ? f.cause : _describe(e),
      );
    }

    final profile = VmProfile(
      id: vmId,
      name: draft.name.trim(),
      guestOs: draft.guestOs,
      guestArch: draft.guestArch,
      cpuCount: draft.cpuCount,
      memoryMiB: draft.memoryMiB,
      disks: [DiskRef(path: diskPath, virtualSizeBytes: draft.diskBytes)],
      media: draft.media,
      network: draft.network,
      sharedFolders: draft.sharedFolders,
      batterySaver: draft.batterySaver,
      licenseAcknowledged: draft.licenseAcknowledged,
      createdAt: _now().toUtc(),
    );
    try {
      await repository.save(profile);
    } on Object catch (e) {
      await _quietDelete(diskPath);
      return CommandResult.failed(
        StartFailure('save profile', _describe(e)),
        _describe(e),
      );
    }
    _profiles[vmId] = profile;
    _notify();
    return CommandResult.okWith(profile);
  }

  /// Edits a powered-off VM with the same validation as create (Req 3.8).
  /// Any other state is rejected and the stored profile stays unchanged
  /// (Req 3.9). The disk is not changed: [ProfileDraft.diskBytes] is
  /// ignored.
  Future<CommandResult> edit(String id, ProfileDraft draft) async {
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final state = stateOf(id);
    if (state != VmState.poweredOff) {
      return CommandResult.rejected(
        'Cannot edit a VM that is ${state.name}. Power it off first.',
      );
    }
    final issues = await validate(draft.copyWith(diskBytes: 0), editingId: id);
    if (issues.isNotEmpty) return CommandResult.invalid(issues);
    return _store(
      profile.copyWith(
        name: draft.name.trim(),
        guestOs: draft.guestOs,
        guestArch: draft.guestArch,
        cpuCount: draft.cpuCount,
        memoryMiB: draft.memoryMiB,
        media: draft.media,
        network: draft.network,
        sharedFolders: draft.sharedFolders,
        batterySaver: draft.batterySaver,
        licenseAcknowledged: draft.licenseAcknowledged,
      ),
      'save profile',
    );
  }

  /// Saves [updated] and replaces the in-memory copy only on success.
  Future<CommandResult> _store(VmProfile updated, String step) async {
    try {
      await repository.save(updated);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure(step, _describe(e)),
        _describe(e),
      );
    }
    _profiles[updated.id] = updated;
    _notify();
    return CommandResult.okWith(updated);
  }

  Future<void> _quietDelete(String path) async {
    try {
      await fileOps.deletePath(path);
    } on Object {
      // Cleanup after a failure must not hide the original error.
    }
  }

  /// A disk file this VM owns: inside its VM folder, or in a folder named
  /// after the VM id (removable storage). Other disk paths, for example
  /// from an imported profile, are never deleted.
  bool _ownsDisk(String id, String path) =>
      p.isWithin(layout.vmDir(id), path) || p.basename(p.dirname(path)) == id;

  /// Deletes the profile, disks, snapshots and copied media (Req 8.3).
  /// Media referenced in place is never touched (Req 8.4). The caller must
  /// pass `confirmed: true` after asking the user.
  Future<CommandResult> delete(String id, {required bool confirmed}) async {
    if (!confirmed) {
      return const CommandResult.rejected('Delete needs confirmation.');
    }
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final state = stateOf(id);
    if (state != VmState.poweredOff && state != VmState.error) {
      return CommandResult.rejected(
        'Cannot delete a VM that is ${state.name}. Power it off first.',
      );
    }
    try {
      for (final d in profile.disks) {
        if (_ownsDisk(id, d.path)) await fileOps.deletePath(d.path);
      }
      // The VM folder holds snapshots.json, run sockets and copied media.
      await fileOps.deletePath(layout.vmDir(id));
      await fileOps.deletePath(layout.logPath(id));
      await repository.delete(id);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure('delete', _describe(e)),
        _describe(e),
      );
    }
    _profiles.remove(id);
    _runtime.remove(id);
    _notify();
    return const CommandResult.ok();
  }

  /// Clones a powered-off VM: new id, unique name, same settings, and a
  /// copy of each disk and copied media file (Req 10.4).
  Future<CommandResult> clone(String id) async {
    final src = _profiles[id];
    if (src == null) return const CommandResult.rejected('Unknown VM.');
    final state = stateOf(id);
    if (state != VmState.poweredOff) {
      return CommandResult.rejected(
        'Cannot clone a VM that is ${state.name}. Power it off first.',
      );
    }
    final newId = _newId();
    final created = <String>[];
    try {
      final disks = <DiskRef>[];
      for (final (i, d) in src.disks.indexed) {
        final dest = _cloneDiskPath(id, newId, d.path, i);
        await fileOps.copyFile(d.path, dest);
        created.add(dest);
        disks.add(d.copyWith(path: dest, status: MediaStatus.present));
      }
      final media = <MediaRef>[];
      for (final m in src.media) {
        if (m.copiedIntoAppStorage && p.isWithin(layout.mediaDir(id), m.path)) {
          final dest = p.join(layout.mediaDir(newId), p.basename(m.path));
          await fileOps.copyFile(m.path, dest);
          created.add(dest);
          media.add(m.copyWith(path: dest));
        } else {
          media.add(m);
        }
      }
      final clone = src.copyWith(
        id: newId,
        name: CloneNamer.uniqueName(
          src.name,
          _profiles.values.map((v) => v.name),
        ),
        disks: disks,
        media: media,
        createdAt: _now().toUtc(),
      );
      await repository.save(clone);
      _profiles[newId] = clone;
      _notify();
      return CommandResult.okWith(clone);
    } on Object catch (e) {
      for (final path in created) {
        await _quietDelete(path);
      }
      await _quietDelete(layout.vmDir(newId));
      return CommandResult.failed(
        StartFailure('clone', _describe(e)),
        _describe(e),
      );
    }
  }

  /// Keeps a clone next to its source: same VM folder layout or the same
  /// removable volume.
  String _cloneDiskPath(String srcId, String newId, String path, int i) {
    if (p.isWithin(layout.vmDir(srcId), path)) {
      return p.join(layout.disksDir(newId), p.basename(path));
    }
    if (p.basename(p.dirname(path)) == srcId) {
      return p.join(p.dirname(p.dirname(path)), newId, p.basename(path));
    }
    return p.join(layout.disksDir(newId), 'disk$i.qcow2');
  }

  /// The VM_Profile_File JSON for [id], without disk content (Req 10.5).
  String? exportProfile(String id) {
    final profile = _profiles[id];
    return profile == null ? null : const ProfileSerializer().print(profile);
  }

  /// Parses [json] and adds the profile (Req 10.6). A malformed file or
  /// unsupported version is rejected with the offending field or version
  /// (Req 10.7). A taken id gets a fresh one, a taken name a unique one, and
  /// files that are not on this device are marked Missing (Req 10.9).
  Future<CommandResult> importProfile(String json) async {
    final parsed = const ProfileSerializer().parse(json);
    if (parsed is Failure) {
      return CommandResult.rejected(parsed.error.message);
    }
    var profile = (parsed as Success).profile;
    profile = ProfileImport.withFreshIdIfTaken(profile, _profiles.keys, _newId);
    final names = _profiles.values.map((v) => v.name).toList();
    if (names.any((n) => n.toLowerCase() == profile.name.toLowerCase())) {
      profile = profile.copyWith(
        name: CloneNamer.uniqueName(profile.name, names),
      );
    }
    final present = <String>{};
    for (final path in [
      ...profile.disks.map((d) => d.path),
      ...profile.media.map((m) => m.path),
    ]) {
      if (await _exists(path)) present.add(path);
    }
    profile = MediaPreflight.markMissing(profile, present.contains);
    return _store(profile, 'save profile');
  }

  // ---------------------------------------------------------------------
  // Media and shared folders (Req 4.1 to 4.7, 11.6)
  // ---------------------------------------------------------------------

  /// Opens the system file picker. Null when the user cancels.
  Future<PickedMedia?> pickMedia() => files.pickMedia();

  /// Checks the format and, when [copy] is set, copies the file into the
  /// VM's media folder after checking free storage (Req 4.2, 4.3, 4.4,
  /// 4.6). Without [copy] the file is referenced in place. Progress
  /// arrives on [copyProgress].
  Future<MediaPrep> prepareMedia(
    PickedMedia picked, {
    required String vmId,
    bool copy = false,
  }) async {
    final kind = MediaFilter.kindOf(picked.name);
    if (kind == null || !picked.supported) {
      return MediaPrep.rejected(MediaFilter.rejectionMessage(picked.name));
    }
    if (!copy) {
      // QEMU opens the file by real path, which needs All-files access.
      if (!await hasAllFilesAccess()) {
        return const MediaPrep.rejected(
          'Using a file in place needs All-files access. Grant it in '
          'Settings, or copy the file into app storage instead.',
          problem: MediaProblem.allFilesAccess,
        );
      }
      String? real;
      try {
        real = await files.resolveRealPath(picked.uri);
      } on PlatformException {
        real = null;
      }
      if (real == null) {
        return MediaPrep.rejected(
          'Could not find the real file path for ${picked.name}. This '
          'happens with cloud or virtual storage. Copy the file into app '
          'storage instead.',
          problem: MediaProblem.unresolvable,
        );
      }
      return MediaPrep.ready(
        MediaRef(path: real, kind: kind, displayName: picked.name),
      );
    }

    final dir = layout.mediaDir(vmId);
    var dest = p.join(dir, p.basename(picked.name));
    for (var n = 2; await pathExists(dest); n++) {
      dest = p.join(
        dir,
        '${p.basenameWithoutExtension(picked.name)} $n${p.extension(picked.name)}',
      );
    }
    try {
      await fileOps.ensureDir(dir);
      final size = picked.size;
      final available = await files.freeSpace(dir);
      if (size != null && available != null) {
        final check = StorageCheck.hasRoom(size, available);
        if (!check.ok) return MediaPrep.rejected(check.message!);
      }
      final r = await files.copyMedia(picked.uri, dest);
      if (!r.ok) {
        await _quietDelete(dest);
        final needed = r.required ?? size;
        final free = r.available ?? available;
        final check = needed != null && free != null
            ? StorageCheck.hasRoom(needed, free)
            : const StorageCheckResult.ok();
        return MediaPrep.rejected(
          r.error == 'cancelled'
              ? 'Copy cancelled.'
              : check.message ?? r.message ?? 'Copying the file failed.',
        );
      }
      return MediaPrep.ready(
        MediaRef(
          path: r.path ?? dest,
          kind: kind,
          copiedIntoAppStorage: true,
          displayName: picked.name,
        ),
      );
    } on PlatformException catch (e) {
      await _quietDelete(dest);
      return MediaPrep.rejected(_describe(e));
    }
  }

  /// Prepares [picked] and attaches it to a powered-off VM.
  Future<CommandResult> attachMedia(
    String id,
    PickedMedia picked, {
    bool copy = false,
  }) async {
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final blocked = _requirePoweredOff(id, 'change media of');
    if (blocked != null) return blocked;
    final prep = await prepareMedia(picked, vmId: id, copy: copy);
    if (!prep.ok) return CommandResult.rejected(prep.message!);
    return _store(MediaAttachment.attach(profile, prep.media!), 'attach media');
  }

  /// Removes the media reference only; the file is left in place (Req 4.7).
  Future<CommandResult> detachMedia(String id, String path) async {
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final blocked = _requirePoweredOff(id, 'change media of');
    if (blocked != null) return blocked;
    return _store(MediaAttachment.detach(profile, path), 'detach media');
  }

  /// Removes the share from the profile; files in the folder stay
  /// untouched (Req 11.6).
  Future<CommandResult> removeSharedFolder(
    String id,
    SharedFolder folder,
  ) async {
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final blocked = _requirePoweredOff(id, 'change shared folders of');
    if (blocked != null) return blocked;
    final i = profile.sharedFolders.indexOf(folder);
    if (i < 0) return const CommandResult.rejected('Unknown shared folder.');
    return _store(
      profile.copyWith(sharedFolders: [...profile.sharedFolders]..removeAt(i)),
      'remove shared folder',
    );
  }

  CommandResult? _requirePoweredOff(String id, String what) {
    final s = stateOf(id);
    return s == VmState.poweredOff
        ? null
        : CommandResult.rejected(
            'Cannot $what a VM that is ${s.name}. Power it off first.',
          );
  }

  // ---------------------------------------------------------------------
  // Snapshots (Req 9.1 to 9.5)
  // ---------------------------------------------------------------------

  /// Snapshots recorded for [id] in `snapshots.json`, oldest first. A
  /// missing or unreadable file gives an empty list.
  Future<List<SnapshotInfo>> snapshots(String id) async {
    final Uint8List? bytes;
    try {
      bytes = await fileOps.readBytes(layout.snapshotsJson(id));
    } on Object {
      return const [];
    }
    if (bytes == null) return const [];
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map)
            SnapshotInfo(
              name: e['name'] as String,
              createdAt: DateTime.parse(e['createdAt'] as String),
              sizeBytes: (e['sizeBytes'] as num).toInt(),
            ),
      ];
    } on Object {
      return const [];
    }
  }

  /// Total bytes used by the snapshots of [id] (Req 8.7, 9.3).
  Future<int> snapshotBytes(String id) async => [
    for (final s in await snapshots(id)) s.sizeBytes,
  ].fold<int>(0, (a, b) => a + b);

  Future<void> _writeSnapshots(String id, List<SnapshotInfo> list) =>
      fileOps.writeBytes(
        layout.snapshotsJson(id),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode([
              for (final s in list)
                {
                  'name': s.name,
                  'createdAt': s.createdAt.toUtc().toIso8601String(),
                  'sizeBytes': s.sizeBytes,
                },
            ]),
          ),
        ),
      );

  /// Whether the VM's first disk is qcow2, the only format with internal
  /// snapshots.
  bool _supportsSnapshots(VmProfile p) =>
      p.disks.isNotEmpty && p.disks.first.path.toLowerCase().endsWith('.qcow2');

  /// Saves the VM state of a running or paused VM under [name] (Req 9.1).
  /// The free storage must cover the estimated size, which is the guest
  /// memory (Req 9.4). Nothing is recorded when the engine fails.
  Future<CommandResult> createSnapshot(String id, String name) async {
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final state = stateOf(id);
    if (state != VmState.running && state != VmState.paused) {
      return CommandResult.rejected(
        'Cannot create a snapshot of a VM that is ${state.name}.',
      );
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const CommandResult.rejected('Snapshot name must not be empty.');
    }
    final existing = await snapshots(id);
    if (existing.any((s) => s.name == trimmed)) {
      return CommandResult.rejected('A snapshot named "$trimmed" exists.');
    }

    final estimate = profile.memoryMiB * 1024 * 1024;
    int? available;
    try {
      available = await files.freeSpace(layout.vmDir(id));
    } on PlatformException {
      available = null;
    }
    available ??= (await _ensureHost()).freeStorageBytes.valueOrNull;
    if (available != null) {
      final check = StorageCheck.hasRoom(estimate, available);
      if (!check.ok) return CommandResult.rejected(check.message!);
    }

    try {
      await engine.snapshotCreate(id, trimmed);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure('snapshot', _describe(e)),
        _describe(e),
      );
    }
    try {
      await _writeSnapshots(id, [
        ...existing,
        SnapshotInfo(
          name: trimmed,
          createdAt: _now().toUtc(),
          sizeBytes: estimate,
        ),
      ]);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure('save snapshot list', _describe(e)),
        _describe(e),
      );
    }
    _notify();
    return const CommandResult.ok();
  }

  /// Restores a powered-off VM to [name] after the user confirmed (Req 9.2).
  /// The engine restores against a temporary copy and replaces the disk only
  /// on success, so a failure leaves the disk unchanged (Req 9.5); the
  /// controller never writes to the disk itself.
  Future<CommandResult> restoreSnapshot(
    String id,
    String name, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      return const CommandResult.rejected('Restore needs confirmation.');
    }
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final blocked = _requirePoweredOff(id, 'restore a snapshot of');
    if (blocked != null) return blocked;
    if (profile.disks.isEmpty) {
      return const CommandResult.rejected('The VM has no disk.');
    }
    if (!(await snapshots(id)).any((s) => s.name == name)) {
      return CommandResult.rejected('Unknown snapshot "$name".');
    }
    try {
      await engine.snapshotRestore(id, name, disk: profile.disks.first.path);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure('restore snapshot', _describe(e)),
        _describe(e),
      );
    }
    _notify();
    return const CommandResult.ok();
  }

  /// Removes [name] and releases its storage after confirmation (Req 9.3).
  Future<CommandResult> deleteSnapshot(
    String id,
    String name, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      return const CommandResult.rejected('Delete needs confirmation.');
    }
    final profile = _profiles[id];
    if (profile == null) return const CommandResult.rejected('Unknown VM.');
    final state = stateOf(id);
    if (state != VmState.poweredOff && state != VmState.error) {
      return CommandResult.rejected(
        'Cannot delete a snapshot of a VM that is ${state.name}. '
        'Power it off first.',
      );
    }
    if (profile.disks.isEmpty) {
      return const CommandResult.rejected('The VM has no disk.');
    }
    final existing = await snapshots(id);
    if (!existing.any((s) => s.name == name)) {
      return CommandResult.rejected('Unknown snapshot "$name".');
    }
    try {
      await engine.snapshotDelete(id, name, disk: profile.disks.first.path);
      await _writeSnapshots(id, [
        for (final s in existing)
          if (s.name != name) s,
      ]);
    } on Object catch (e) {
      return CommandResult.failed(
        StartFailure('delete snapshot', _describe(e)),
        _describe(e),
      );
    }
    _notify();
    return const CommandResult.ok();
  }

  // ---------------------------------------------------------------------
  // Host signals (Req 7.4 to 7.6, 8.6, 11.4)
  // ---------------------------------------------------------------------

  /// Applies [signals]: the guest network flag first, then the actions
  /// [ResourcePolicy] decides. Snapshots run before pauses; a failed
  /// snapshot never prevents the pause. A network change never changes a
  /// VM's state (Req 11.4).
  Future<void> handleHostSignals(HostSignals signals) async {
    final connected = signals.networkConnected;
    if (connected != null) {
      for (final id in _profiles.keys) {
        final cur = runtimeOf(id);
        if (cur.networkConnected != connected) {
          _setRuntime(id, cur.copyWith(networkConnected: connected));
        }
      }
    }
    final vms = [
      for (final p in _profiles.values)
        RunningVmInfo(
          id: p.id,
          state: stateOf(p.id),
          supportsSnapshots: _supportsSnapshots(p),
        ),
    ];
    final runningIds = [
      for (final v in vms)
        if (v.state == VmState.running) v.id,
    ];
    for (final action in ResourcePolicy.decide(signals, vms)) {
      switch (action) {
        case SnapshotVm(:final id):
          await createSnapshot(id, 'auto-${_now().millisecondsSinceEpoch}');
        case PauseVm(:final id):
          await pause(id);
        case NotifyThermalPause():
          _notice(
            HostNoticeKind.thermalPause,
            'The device is overheating. Running VMs were paused.',
            runningIds,
          );
        case NotifyBatteryLow():
          _notice(
            HostNoticeKind.batteryLow,
            'Battery is at $lowBatteryPercent% or lower. '
            'Pause or shut down the running VMs to save power.',
            runningIds,
          );
        case NotifyLowStorage():
          _notice(
            HostNoticeKind.lowStorage,
            'Free storage is below 500 MB. Running VMs were paused.',
            runningIds,
          );
      }
    }
  }

  void _notice(HostNoticeKind kind, String message, List<String> ids) {
    if (!_notices.isClosed) _notices.add(HostNotice(kind, message, ids));
  }

  // ---------------------------------------------------------------------
  // Diagnostics: stats and logs (Req 7.2, 12.2 to 12.5)
  // ---------------------------------------------------------------------

  /// Polls the engine every [interval] while the VM is running or paused
  /// and ends when it is not (Req 7.2). A failed poll skips that sample.
  Stream<VmStats> statsStream(
    String id, {
    Duration interval = const Duration(seconds: 1),
  }) async* {
    while (true) {
      final profile = _profiles[id];
      final state = stateOf(id);
      if (profile == null ||
          (state != VmState.running && state != VmState.paused)) {
        return;
      }
      try {
        final s = await engine.stats(id);
        final host = await _ensureHost();
        yield VmStats(
          cpuPercent: s.cpuPercent ?? 0,
          memBytes: s.memBytes ?? 0,
          mode: LaunchSpecBuilder.accelerationFor(profile, host),
          crossArch: _crossArch(profile, host),
        );
      } on PlatformException {
        // Skip this sample.
      }
      await Future<void>.delayed(interval);
    }
  }

  /// The VM's log text, cut to the newest [logMaxBytes] first (Req 12.3,
  /// 12.5). Empty when there is no log yet.
  Future<String> viewLog(String id) async {
    final bytes = await _rotatedLog(id);
    return bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
  }

  /// Opens the share sheet with the log file attached (Req 12.4).
  Future<CommandResult> shareLog(String id) async {
    if (!_profiles.containsKey(id)) {
      return const CommandResult.rejected('Unknown VM.');
    }
    if (await _rotatedLog(id) == null) {
      return const CommandResult.rejected('There is no log for this VM yet.');
    }
    try {
      final shared = await files.shareLogs(layout.logPath(id));
      return shared
          ? const CommandResult.ok()
          : const CommandResult.rejected('The log could not be shared.');
    } on PlatformException catch (e) {
      return CommandResult.failed(
        StartFailure('share logs', _describe(e)),
        _describe(e),
      );
    }
  }

  /// Reads the log and rewrites it when it exceeds [logMaxBytes].
  Future<Uint8List?> _rotatedLog(String id) async {
    final path = layout.logPath(id);
    final Uint8List? bytes;
    try {
      bytes = await fileOps.readBytes(path);
    } on Object {
      return null;
    }
    if (bytes == null || bytes.length <= logMaxBytes) return bytes;
    final kept = LogRotator.rotate(bytes, Uint8List(0), logMaxBytes);
    try {
      await fileOps.writeBytes(path, kept);
    } on Object {
      // Showing the trimmed text is still correct.
    }
    return kept;
  }

  // ---------------------------------------------------------------------
  // Engine events (Req 5.7, 5.8)
  // ---------------------------------------------------------------------

  void _onEngineEvent(EngineEvent e) {
    switch (e) {
      case EngineStateChanged(:final id, :final state):
        if (!_profiles.containsKey(id)) return;
        switch (state) {
          case 'running':
            _applyEvent(id, const EngineReady()) ||
                _applyEvent(id, const Resume());
          case 'paused':
            _applyEvent(id, const Pause());
          case 'stopping':
            _applyEvent(id, const Shutdown());
        }
      case EngineQmpEvent(:final id, :final event):
        if (!_profiles.containsKey(id)) return;
        switch (event) {
          case 'RESET':
            _applyEvent(id, const EngineReady());
          case 'STOP':
            _applyEvent(id, const Pause());
          case 'RESUME':
            _applyEvent(id, const Resume());
          case 'SHUTDOWN':
            _applyEvent(id, const GuestPoweredOff());
        }
      case EngineStartFailed(:final id, :final step, :final message):
        if (!_profiles.containsKey(id)) return;
        if (_applyEvent(id, EngineCrashed(message))) {
          final p = _profiles[id]!;
          final host = _host ?? const HostCapabilities();
          _recordFailure(id, StartFailure(step, message), _crossArch(p, host));
        }
      case EngineExit():
        if (!_profiles.containsKey(e.id)) return;
        _onExit(e);
      case CopyProgressEvent(:final dest, :final copied, :final total):
        // total is -1 when unknown; no percentage can be shown then.
        if (total > 0 && !_copyProgress.isClosed) {
          _copyProgress.add(
            MediaCopyProgress(dest, CopyProgress.percent(copied, total)),
          );
        }
      case MirrorChanged():
        break;
    }
  }

  /// Maps an engine exit to a state-machine event. The controller never
  /// touches disk images here (Req 5.8).
  void _onExit(EngineExit e) {
    final reason = e.message.isNotEmpty
        ? e.message
        : 'Engine exited (${e.kind}, code ${e.exitCode ?? e.signal ?? '?'}).';
    if (e.crashed) {
      _applyEvent(e.id, EngineCrashed(reason));
      return;
    }
    final expectedKill = e.kind == 'killed' && _forceStopping.contains(e.id);
    final clean = e.kind == 'clean' || expectedKill;
    final code = clean ? 0 : (e.exitCode ?? e.signal ?? 1);
    _applyEvent(
      e.id,
      EngineExited(code: code == 0 && !clean ? 1 : code, reason: reason),
    );
  }
}
