import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../controller/vm_manager_controller.dart';
import '../../domain/domain.dart';
import '../../services/file_service.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'all_files_access_card.dart';
import 'placeholder_screens.dart' show ScreenFrame;

const int _gib = 1024 * 1024 * 1024;

/// Storage label for a media row. It follows the "Copy into app storage"
/// toggle, so it never says "in place" while the toggle is on. A file that
/// was attached before the toggle was switched on is "not copied".
String mediaStorageLabel(MediaRef m, {required bool copyToggle}) {
  if (m.copiedIntoAppStorage) return 'copied';
  return copyToggle ? 'not copied' : 'in place';
}

/// A suggested Linux distribution with its official download page (Req 2.6).
class LinuxDistro {
  const LinuxDistro(this.name, this.url, this.archs);
  final String name;

  /// Always an official `https` page.
  final String url;
  final String archs;
}

/// Suggested distributions that publish ARM64 or x86_64 images.
const List<LinuxDistro> linuxDistros = [
  LinuxDistro('Ubuntu', 'https://ubuntu.com/download/desktop', 'ARM64, x86_64'),
  LinuxDistro('Debian', 'https://www.debian.org/distrib/', 'ARM64, x86_64'),
  LinuxDistro(
    'Fedora',
    'https://fedoraproject.org/workstation/download',
    'ARM64, x86_64',
  ),
  LinuxDistro(
    'Alpine Linux',
    'https://alpinelinux.org/downloads/',
    'ARM64, x86_64',
  ),
  LinuxDistro('Arch Linux ARM', 'https://archlinuxarm.org/', 'ARM64'),
];

/// Create (vmId null) and edit form for a VM profile (task 11.4).
class VmFormScreen extends ConsumerStatefulWidget {
  const VmFormScreen({super.key, this.vmId});
  final String? vmId;

  @override
  ConsumerState<VmFormScreen> createState() => _VmFormScreenState();
}

class _VmFormScreenState extends ConsumerState<VmFormScreen> {
  final _name = TextEditingController();
  final _cpu = TextEditingController();
  final _mem = TextEditingController();
  final _disk = TextEditingController();
  final _hostPort = TextEditingController();
  final _guestPort = TextEditingController();
  final _folderPath = TextEditingController();

  GuestOs _os = GuestOs.linux;
  GuestArch _arch = GuestArch.arm64;
  List<MediaRef> _media = [];
  List<PortForward> _forwards = [];
  List<SharedFolder> _folders = [];
  bool _batterySaver = false;
  bool _ack = false;
  bool _copyMedia = false;
  bool _saving = false;
  bool _picking = false;

  /// A picked file that could not be used in place, with the reason.
  PickedMedia? _offerPicked;
  String? _offerMessage;
  int? _copyPercent;
  int _editDiskBytes = 0;

  List<RemovableVolume> _volumes = const [];
  RemovableVolume? _volume;
  List<ValidationIssue> _issues = const [];
  int _validationSeq = 0;
  StreamSubscription<MediaCopyProgress>? _progressSub;

  late final String _vmId;
  bool get _editing => widget.vmId != null;
  VmManagerController get _c => ref.read(vmManagerControllerProvider);

  @override
  void initState() {
    super.initState();
    _vmId = widget.vmId ?? _c.newVmId();
    final existing = widget.vmId == null ? null : _c.profileOf(widget.vmId!);
    if (existing != null) {
      _name.text = existing.name;
      _os = existing.guestOs;
      _arch = existing.guestArch;
      _cpu.text = '${existing.cpuCount}';
      _mem.text = '${existing.memoryMiB}';
      _editDiskBytes = existing.disks.isEmpty
          ? 0
          : existing.disks.first.virtualSizeBytes;
      _disk.text = _gibText(_editDiskBytes);
      _media = [...existing.media];
      _forwards = [...existing.network.forwards];
      _folders = [...existing.sharedFolders];
      _batterySaver = existing.batterySaver;
      _ack = existing.licenseAcknowledged;
    } else {
      _applyDefaults(_os);
    }
    _progressSub = _c.copyProgress.listen((e) {
      if (mounted) setState(() => _copyPercent = e.percent);
    });
    _load();
  }

  Future<void> _load() async {
    await _c.detectCapabilities();
    final vols = _editing
        ? const <RemovableVolume>[]
        : await _c.removableVolumes();
    if (!mounted) return;
    setState(() => _volumes = vols);
    _revalidate();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    for (final c in [
      _name,
      _cpu,
      _mem,
      _disk,
      _hostPort,
      _guestPort,
      _folderPath,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _gibText(int bytes) {
    final g = bytes / _gib;
    return g == g.roundToDouble() ? '${g.round()}' : g.toStringAsFixed(1);
  }

  void _applyDefaults(GuestOs os) {
    final d = RecommendedDefaults.forOs(os);
    _cpu.text = '${d.cpuCount}';
    _mem.text = '${d.memoryMiB}';
    _disk.text = _gibText(d.diskBytes);
  }

  int get _cpuValue => int.tryParse(_cpu.text.trim()) ?? 0;
  int get _memValue => int.tryParse(_mem.text.trim()) ?? 0;
  int get _diskBytes {
    if (_editing) return _editDiskBytes;
    final g = double.tryParse(_disk.text.trim()) ?? 0;
    return (g * _gib).round();
  }

  ProfileDraft _draft() => ProfileDraft(
    name: _name.text,
    guestOs: _os,
    guestArch: _arch,
    cpuCount: _cpuValue,
    memoryMiB: _memValue,
    diskBytes: _diskBytes,
    media: _media,
    network: NetworkConfig(forwards: _forwards),
    sharedFolders: _folders,
    batterySaver: _batterySaver,
    licenseAcknowledged: _ack,
  );

  Future<void> _revalidate() async {
    final seq = ++_validationSeq;
    final draft = _draft();
    final issues = await _c.validate(
      _editing ? draft.copyWith(diskBytes: 0) : draft,
      editingId: widget.vmId,
      volume: _volume,
    );
    if (!mounted || seq != _validationSeq) return;
    setState(() => _issues = issues);
  }

  void _changed([VoidCallback? fn]) {
    setState(() => fn?.call());
    _revalidate();
  }

  bool get _running {
    if (!_editing) return false;
    return ref.read(vmStateProvider(widget.vmId!)) != VmState.poweredOff;
  }

  bool get _numbersOk =>
      _cpuValue >= 1 && _memValue >= 1 && (_editing || _diskBytes >= 1);

  bool get _canSave =>
      !_saving && !_running && _numbersOk && (_os != GuestOs.macos || _ack);

  Future<void> _save() async {
    setState(() => _saving = true);
    final draft = _draft();
    final CommandResult r = _editing
        ? await _c.edit(widget.vmId!, draft)
        : await _c.create(draft, id: _vmId, volume: _volume);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!r.ok && r.issues.isNotEmpty) _issues = r.issues;
    });
    if (r.ok) {
      AppToast.show(context, _editing ? 'VM saved' : 'VM created');
      Navigator.of(context).maybePop();
    } else {
      AppToast.show(
        context,
        r.message ?? 'Could not save the VM.',
        error: true,
      );
    }
  }

  Future<void> _pickMedia() async {
    setState(() => _picking = true);
    try {
      final picked = await _c.pickMedia();
      if (picked == null || !mounted) return;
      await _attachPicked(picked, copy: _copyMedia);
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _copyPercent = null;
        });
      }
    }
  }

  Future<void> _attachPicked(PickedMedia picked, {required bool copy}) async {
    setState(() {
      _offerPicked = null;
      _offerMessage = null;
      _copyPercent = copy ? 0 : null;
    });
    final prep = await _c.prepareMedia(picked, vmId: _vmId, copy: copy);
    if (!mounted) return;
    if (!prep.ok) {
      if (prep.copyWouldHelp && !copy) {
        setState(() {
          _offerPicked = picked;
          _offerMessage = prep.message;
        });
      } else {
        AppToast.show(context, prep.message!, error: true);
      }
    } else if (_media.any((m) => m.path == prep.media!.path)) {
      AppToast.show(context, 'That file is already attached.', error: true);
    } else {
      _changed(() => _media = [..._media, prep.media!]);
    }
  }

  Future<void> _copyOffered() async {
    final picked = _offerPicked;
    if (picked == null || _picking) return;
    setState(() => _picking = true);
    try {
      await _attachPicked(picked, copy: true);
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _copyPercent = null;
        });
      }
    }
  }

  void _addForward() {
    final h = int.tryParse(_hostPort.text.trim());
    final g = int.tryParse(_guestPort.text.trim());
    if (h == null || g == null || g < 1 || g > 65535) {
      AppToast.show(
        context,
        'Enter a host port and a guest port.',
        error: true,
      );
      return;
    }
    _hostPort.clear();
    _guestPort.clear();
    _changed(
      () => _forwards = [..._forwards, PortForward(hostPort: h, guestPort: g)],
    );
  }

  void _addFolder() {
    final path = _folderPath.text.trim();
    if (path.isEmpty) return;
    var tag = p.basename(path).replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (tag.isEmpty) tag = 'share';
    final base = tag;
    for (var n = 2; _folders.any((f) => f.mountTag == tag); n++) {
      tag = '${base}_$n';
    }
    _folderPath.clear();
    _changed(
      () => _folders = [
        ..._folders,
        SharedFolder(androidPath: path, mountTag: tag),
      ],
    );
  }

  void _setOs(GuestOs os) {
    _changed(() {
      _os = os;
      if (!_editing) _applyDefaults(os);
      if (os != GuestOs.macos) _ack = false;
    });
  }

  String? _issueFor(ValidationField f) {
    final m = [
      for (final i in _issues)
        if (i.field == f) i.message,
    ];
    return m.isEmpty ? null : m.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the VM state changes so fields lock while running.
    if (_editing) ref.watch(vmStateProvider(widget.vmId!));
    final locked = _running || _saving;
    final report = _c.report;
    final entry = report?.entryFor(_os, _arch);
    final theme = Theme.of(context).textTheme;

    return ScreenFrame(
      title: _editing ? 'Edit VM' : 'New VM',
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_running)
            _notice(
              Icons.lock_outline_rounded,
              'This VM is not powered off, so its settings cannot be edited. '
              'Power it off first.',
              AppColors.warning,
            ),
          _section('Basics', [
            TextField(
              controller: _name,
              enabled: !locked,
              decoration: _dec(
                'VM name',
                error: _issueFor(ValidationField.name),
              ),
              onChanged: (_) => _revalidate(),
            ),
            const SizedBox(height: 14),
            _label('Guest OS'),
            _choices<GuestOs>(
              GuestOs.values,
              _os,
              locked ? null : _setOs,
              (o) => switch (o) {
                GuestOs.linux => 'Linux',
                GuestOs.windows => 'Windows',
                GuestOs.macos => 'macOS',
              },
            ),
            const SizedBox(height: 14),
            _label('Architecture'),
            _choices<GuestArch>(
              GuestArch.values,
              _arch,
              locked ? null : (a) => _changed(() => _arch = a),
              (a) => a == GuestArch.arm64 ? 'ARM64' : 'x86_64',
            ),
            if (ArchMismatchDetector.hint(_media, _arch) case final hint?) ...[
              const SizedBox(height: 12),
              _notice(Icons.warning_amber_rounded, hint, AppColors.warning),
            ],
            if (entry != null && !entry.runnable) ...[
              const SizedBox(height: 12),
              _notice(
                Icons.block_rounded,
                entry.blockedReason ??
                    'This combination cannot run on this device, so the VM cannot be started.',
                AppColors.danger,
              ),
            ],
            if (entry != null &&
                entry.warnings.contains(
                  CompatibilityWarning.reducedPerformance,
                )) ...[
              const SizedBox(height: 12),
              _notice(
                Icons.speed_rounded,
                'x86_64 guests run through software emulation on this device and will be slow.',
                AppColors.warning,
              ),
            ],
            if (entry != null &&
                entry.warnings.contains(
                  CompatibilityWarning.notRecommendedLowRam,
                )) ...[
              const SizedBox(height: 12),
              _notice(
                Icons.memory_rounded,
                'This device has less than 4 GiB of RAM. ${_os == GuestOs.windows ? 'Windows' : 'macOS'} is not recommended.',
                AppColors.warning,
              ),
            ],
          ]).riseIn(),
          const SizedBox(height: 14),
          if (_os == GuestOs.windows)
            _notice(
              Icons.gavel_rounded,
              'You are responsible for holding a valid Windows license. '
              'Windows installation media is not provided by this app.',
              AppColors.blue,
            ),
          if (_os == GuestOs.macos) ...[
            _notice(
              Icons.gavel_rounded,
              "Apple's license permits macOS to run only on Apple-branded "
              'hardware. macOS support is experimental and unsupported.',
              AppColors.warning,
            ),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _ack,
                onChanged: locked
                    ? null
                    : (v) => _changed(() => _ack = v ?? false),
                title: const Text(
                  'I have read and accept this licensing notice',
                ),
              ),
            ),
            if (_issueFor(ValidationField.license) != null && !_ack)
              _error(_issueFor(ValidationField.license)!),
            const SizedBox(height: 14),
          ],
          if (_os == GuestOs.linux) ...[
            _distroCard(),
            const SizedBox(height: 14),
          ],
          _section('Resources', [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _cpu,
                    enabled: !locked,
                    keyboardType: TextInputType.number,
                    decoration: _dec(
                      'vCPUs',
                      error: _issueFor(ValidationField.cpu),
                    ),
                    onChanged: (_) => _changed(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _mem,
                    enabled: !locked,
                    keyboardType: TextInputType.number,
                    decoration: _dec(
                      'Memory (MiB)',
                      error: _issueFor(ValidationField.memory),
                    ),
                    onChanged: (_) => _changed(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _disk,
              enabled: !locked && !_editing,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _dec(
                'Disk size (GiB)',
                error: _issueFor(ValidationField.disk),
                helper: _editing
                    ? 'The disk size cannot be changed after creation.'
                    : null,
              ),
              onChanged: (_) => _changed(),
            ),
            if (_volumes.isNotEmpty) ...[
              const SizedBox(height: 14),
              _label('Disk location'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _choiceChip(
                    'Internal storage',
                    _volume == null,
                    locked ? null : () => _changed(() => _volume = null),
                  ),
                  for (final v in _volumes)
                    _choiceChip(
                      v.description.isEmpty ? v.path : v.description,
                      _volume == v,
                      locked ? null : () => _changed(() => _volume = v),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _batterySaver,
              onChanged: locked
                  ? null
                  : (v) => _changed(() => _batterySaver = v),
              title: const Text('Battery saver'),
              subtitle: const Text('Limits the VM to half of its vCPUs.'),
            ),
          ]).riseIn(index: 1),
          const SizedBox(height: 14),
          _section('Installation media', [
            if (_media.isEmpty)
              Text(
                'No media attached.',
                style: theme.bodyMedium?.copyWith(color: AppColors.muted),
              ),
            for (final m in _media)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.album_outlined,
                  color: AppColors.purple,
                ),
                title: Text(m.label, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${m.kind.name.toUpperCase()} · '
                  '${mediaStorageLabel(m, copyToggle: _copyMedia)}',
                ),
                trailing: IconButton(
                  tooltip: 'Detach',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: locked
                      ? null
                      : () => _changed(() => _media = [..._media]..remove(m)),
                ),
              ),
            if (_issueFor(ValidationField.media) != null)
              _error(_issueFor(ValidationField.media)!),
            if (!_copyMedia || _offerMessage != null)
              AllFilesAccessCard(
                problem: _offerMessage,
                onCopyInstead: _offerPicked == null ? null : _copyOffered,
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _copyMedia,
              onChanged: locked || _picking
                  ? null
                  : (v) => setState(() => _copyMedia = v),
              title: const Text('Copy into app storage'),
              subtitle: const Text('Otherwise the file is used where it is.'),
            ),
            if (_picking && _copyPercent != null) ...[
              LinearProgressIndicator(value: _copyPercent! / 100),
              const SizedBox(height: 6),
              Text('Copying… $_copyPercent%'),
              const SizedBox(height: 6),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: GhostButton(
                label: 'Add media',
                icon: Icons.add_rounded,
                onPressed: locked || _picking ? null : _pickMedia,
              ),
            ),
          ]).riseIn(index: 2),
          const SizedBox(height: 14),
          _section('Network', [
            Text(
              'NAT. Forward a host port to a guest port.',
              style: theme.bodyMedium?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in _forwards)
                  InputChip(
                    label: Text('${f.hostPort} → ${f.guestPort}'),
                    onDeleted: locked
                        ? null
                        : () => _changed(
                            () => _forwards = [..._forwards]..remove(f),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _hostPort,
                    enabled: !locked,
                    keyboardType: TextInputType.number,
                    decoration: _dec('Host port'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _guestPort,
                    enabled: !locked,
                    keyboardType: TextInputType.number,
                    decoration: _dec('Guest port'),
                  ),
                ),
                IconButton(
                  tooltip: 'Add forward',
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: locked ? null : _addForward,
                ),
              ],
            ),
            if (_issueFor(ValidationField.port) != null)
              _error(_issueFor(ValidationField.port)!),
          ]).riseIn(index: 3),
          const SizedBox(height: 14),
          _section('Shared folders', [
            for (final f in _folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.folder_open_rounded,
                  color: AppColors.blue,
                ),
                title: Text(f.androidPath, overflow: TextOverflow.ellipsis),
                subtitle: Text('Mount tag: ${f.mountTag}'),
                trailing: IconButton(
                  tooltip: 'Remove share',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: locked
                      ? null
                      : () =>
                            _changed(() => _folders = [..._folders]..remove(f)),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _folderPath,
                    enabled: !locked,
                    decoration: _dec('Android folder path'),
                    onSubmitted: (_) => _addFolder(),
                  ),
                ),
                IconButton(
                  tooltip: 'Add shared folder',
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: locked ? null : _addFolder,
                ),
              ],
            ),
          ]).riseIn(index: 4),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: PrimaryButton(
              label: _saving
                  ? 'Saving…'
                  : (_editing ? 'Save changes' : 'Create VM'),
              icon: Icons.check_rounded,
              onPressed: _canSave ? _save : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _distroCard() => _section('Suggested distributions', [
    Text(
      'Opens the official download page in your browser.',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
    ),
    const SizedBox(height: 8),
    for (final d in linuxDistros)
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(d.name),
        subtitle: Text(d.archs),
        trailing: const Icon(Icons.open_in_new_rounded, size: 18),
        onTap: () async {
          final ok = await _c.files.openUrl(d.url);
          if (!ok && mounted) {
            AppToast.show(
              context,
              'Could not open the download page.',
              error: true,
            );
          }
        },
      ),
  ]);

  Widget _section(String title, List<Widget> children) => GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );

  Widget _notice(IconData icon, String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );

  Widget _error(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: const TextStyle(color: AppColors.danger, fontSize: 12.5),
    ),
  );

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      t,
      style: const TextStyle(
        color: AppColors.muted,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  InputDecoration _dec(String label, {String? error, String? helper}) =>
      InputDecoration(
        labelText: label,
        errorText: error,
        errorMaxLines: 4,
        helperText: helper,
        helperMaxLines: 2,
      );

  Widget _choiceChip(String label, bool selected, VoidCallback? onTap) =>
      ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: onTap == null ? null : (_) => onTap(),
      );

  Widget _choices<T>(
    List<T> values,
    T current,
    void Function(T)? onSelect,
    String Function(T) label,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final v in values)
        _choiceChip(
          label(v),
          v == current,
          onSelect == null ? null : () => onSelect(v),
        ),
    ],
  );
}
