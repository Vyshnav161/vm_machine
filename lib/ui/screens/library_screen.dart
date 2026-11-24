import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controller/vm_manager_controller.dart';
import '../../domain/domain.dart';
import '../app_router.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'placeholder_screens.dart' show ScreenFrame;

String guestOsLabel(GuestOs os) => switch (os) {
  GuestOs.linux => 'Linux',
  GuestOs.windows => 'Windows',
  GuestOs.macos => 'macOS',
};

String guestArchLabel(GuestArch a) => switch (a) {
  GuestArch.arm64 => 'ARM64',
  GuestArch.x86_64 => 'x86_64',
};

/// Display names for the six lifecycle states (Req 5.7).
String vmStateLabel(VmState s) => switch (s) {
  VmState.poweredOff => 'Powered Off',
  VmState.starting => 'Starting',
  VmState.running => 'Running',
  VmState.paused => 'Paused',
  VmState.stopping => 'Stopping',
  VmState.error => 'Error',
};

/// VM library tab: search, per-VM actions, import (Req 10.2 to 10.6).
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vms = ref.watch(filteredLibraryProvider);
    final total = ref.watch(vmLibraryProvider).length;
    final query = ref.watch(libraryQueryProvider);

    return ScreenFrame(
      title: 'Library',
      showBack: false,
      bottomPadding: 100,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: 'New VM',
                  icon: Icons.add_rounded,
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.form),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GhostButton(
                  label: 'Import',
                  icon: Icons.file_download_outlined,
                  onPressed: () => _import(context, ref),
                ),
              ),
            ],
          ).riseIn(index: 1),
          const SizedBox(height: 14),
          TextField(
            key: const Key('library-search'),
            onChanged: ref.read(libraryQueryProvider.notifier).set,
            decoration: const InputDecoration(
              hintText: 'Search VMs',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ).riseIn(index: 2),
          const SizedBox(height: 14),
          if (vms.isEmpty)
            GlassCard(
              child: Text(
                total == 0
                    ? 'No VMs yet. Create one or import a profile.'
                    : 'No VMs match "$query".',
                style: const TextStyle(color: AppColors.muted),
              ),
            ).riseIn(index: 3)
          else
            for (var i = 0; i < vms.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _VmCard(vm: vms[i]).riseIn(index: 3 + i.clamp(0, 6)),
              ),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(vmManagerControllerProvider);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _ImportDialog(initial: data?.text ?? ''),
    );
    if (text == null || text.trim().isEmpty) return;
    final r = await controller.importProfile(text);
    if (!context.mounted) return;
    AppToast.show(
      context,
      r.ok ? 'Imported ${r.profile?.name ?? 'profile'}' : _msg(r),
      error: !r.ok,
    );
  }
}

String _msg(CommandResult r) => r.message ?? 'Something went wrong.';

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.initial});
  final String initial;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import profile'),
    content: TextField(
      key: const Key('import-json'),
      controller: _c,
      maxLines: 8,
      decoration: const InputDecoration(
        hintText: 'Paste the exported profile JSON',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('import-confirm'),
        onPressed: () => Navigator.pop(context, _c.text),
        child: const Text('Import'),
      ),
    ],
  );
}

class _VmCard extends ConsumerWidget {
  const _VmCard({required this.vm});
  final VmProfile vm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vmStateProvider(vm.id));
    final controller = ref.read(vmManagerControllerProvider);
    final off = state == VmState.poweredOff || state == VmState.error;
    final live =
        state == VmState.starting ||
        state == VmState.running ||
        state == VmState.paused;
    final nav = Navigator.of(context);

    return GlassCard(
      onTap: () => nav.pushNamed(AppRoutes.details, arguments: vm.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  vm.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 8),
              PillChip(
                vmStateLabel(state),
                pulsingDot: state == VmState.running,
                dotColor: AppColors.success,
                icon: switch (state) {
                  VmState.error => Icons.error_outline_rounded,
                  VmState.paused => Icons.pause_rounded,
                  _ => null,
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PillChip(guestOsLabel(vm.guestOs)),
              PillChip(guestArchLabel(vm.guestArch)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            children: [
              if (off)
                TextButton.icon(
                  onPressed: () => _start(context, ref),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start'),
                ),
              if (live)
                TextButton.icon(
                  onPressed: () =>
                      nav.pushNamed(AppRoutes.console, arguments: vm.id),
                  icon: const Icon(Icons.desktop_windows_rounded),
                  label: const Text('Console'),
                ),
              if (state == VmState.poweredOff)
                TextButton.icon(
                  onPressed: () async {
                    final r = await controller.clone(vm.id);
                    if (!context.mounted) return;
                    AppToast.show(
                      context,
                      r.ok ? 'Cloned as ${r.profile?.name}' : _msg(r),
                      error: !r.ok,
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Clone'),
                ),
              TextButton.icon(
                onPressed: () => _export(context, ref),
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('Export'),
              ),
              if (off)
                TextButton.icon(
                  onPressed: () => _delete(context, ref),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.danger,
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final nav = Navigator.of(context);
    final r = await ref.read(vmManagerControllerProvider).start(vm.id);
    if (!context.mounted) return;
    if (r.ok) {
      nav.pushNamed(AppRoutes.console, arguments: vm.id);
    } else {
      AppToast.show(context, _msg(r), error: true);
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final json = ref.read(vmManagerControllerProvider).exportProfile(vm.id);
    if (json == null) {
      AppToast.show(context, 'Unknown VM.', error: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    AppToast.show(context, 'Profile JSON copied to the clipboard');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(vmManagerControllerProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${vm.name}?'),
        content: const Text(
          'This removes the profile, its disks and its snapshots. '
          'Installation media files you referenced are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await controller.delete(vm.id, confirmed: true);
    if (!context.mounted) return;
    AppToast.show(context, r.ok ? 'Deleted ${vm.name}' : _msg(r), error: !r.ok);
  }
}
