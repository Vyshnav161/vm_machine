import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controller/vm_manager_controller.dart';
import '../../domain/domain.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'placeholder_screens.dart' show ScreenFrame;
import 'storage_overview_screen.dart' show formatBytes;

/// Snapshots of one VM, recomputed on every controller change.
final vmSnapshotsProvider = FutureProvider.family<List<SnapshotInfo>, String>((
  ref,
  id,
) {
  ref.watch(vmChangesProvider);
  return ref.watch(vmManagerControllerProvider).snapshots(id);
});

/// Snapshot list with create, restore and delete (Req 9.1 to 9.5).
class SnapshotsScreen extends ConsumerWidget {
  const SnapshotsScreen({super.key, required this.vmId});

  final String vmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(vmProfileProvider(vmId));
    final state = ref.watch(vmStateProvider(vmId));
    final snaps = ref.watch(vmSnapshotsProvider(vmId));
    final live = state == VmState.running || state == VmState.paused;
    final off = state == VmState.poweredOff || state == VmState.error;

    return ScreenFrame(
      title: 'Snapshots',
      body: profile == null
          ? const GlassCard(child: Text('This VM no longer exists.'))
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        live
                            ? 'Create a snapshot of the running VM.'
                            : 'Snapshots can be created while the VM runs '
                                  'and restored or deleted while it is off.',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(
                        label: 'Create snapshot',
                        icon: Icons.add_a_photo_outlined,
                        onPressed: live ? () => _create(context, ref) : null,
                      ),
                    ],
                  ),
                ).riseIn(index: 1),
                const SizedBox(height: 14),
                snaps.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) =>
                      GlassCard(child: Text('Could not read snapshots: $e')),
                  data: (list) => list.isEmpty
                      ? const GlassCard(child: Text('No snapshots yet.'))
                      : Column(
                          children: [
                            for (final s in list)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _SnapshotCard(
                                  vmId: vmId,
                                  info: s,
                                  canChange: off,
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(vmManagerControllerProvider);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name == null) return;
    final r = await controller.createSnapshot(vmId, name);
    if (!context.mounted) return;
    _report(context, r, 'Snapshot created');
  }
}

void _report(BuildContext context, CommandResult r, String okText) {
  AppToast.show(
    context,
    r.ok ? okText : (r.message ?? 'Something went wrong.'),
    error: !r.ok,
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New snapshot'),
    content: TextField(
      key: const Key('snapshot-name'),
      controller: _c,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Snapshot name'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('snapshot-create-confirm'),
        onPressed: () => Navigator.pop(context, _c.text),
        child: const Text('Create'),
      ),
    ],
  );
}

class _SnapshotCard extends ConsumerWidget {
  const _SnapshotCard({
    required this.vmId,
    required this.info,
    required this.canChange,
  });

  final String vmId;
  final SnapshotInfo info;
  final bool canChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = info.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(info.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PillChip(when, icon: Icons.schedule_rounded),
              PillChip(formatBytes(info.sizeBytes), icon: Icons.storage),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: canChange ? () => _restore(context, ref) : null,
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Restore'),
              ),
              TextButton.icon(
                onPressed: canChange ? () => _delete(context, ref) : null,
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

  Future<bool> _confirm(
    BuildContext context,
    String title,
    String body,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('snapshot-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(vmManagerControllerProvider);
    final ok = await _confirm(
      context,
      'Restore "${info.name}"?',
      'The VM disk returns to this snapshot. Changes made since are lost.',
      'Restore',
    );
    if (!ok) return;
    final r = await controller.restoreSnapshot(
      vmId,
      info.name,
      confirmed: true,
    );
    if (!context.mounted) return;
    _report(context, r, 'Snapshot restored');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(vmManagerControllerProvider);
    final ok = await _confirm(
      context,
      'Delete "${info.name}"?',
      'The snapshot and its storage are removed.',
      'Delete',
    );
    if (!ok) return;
    final r = await controller.deleteSnapshot(vmId, info.name, confirmed: true);
    if (!context.mounted) return;
    _report(context, r, 'Snapshot deleted');
  }
}
