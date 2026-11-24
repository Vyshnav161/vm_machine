import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/domain.dart';
import '../app_router.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'library_screen.dart' show guestArchLabel, guestOsLabel, vmStateLabel;
import 'logs_screen.dart' show showStartFailureDialog;
import 'placeholder_screens.dart' show ScreenFrame;

/// Details of one VM with links to console, edit, media, snapshots, logs.
class VmDetailsScreen extends ConsumerWidget {
  const VmDetailsScreen({super.key, required this.vmId});

  final String vmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(vmProfileProvider(vmId));
    final runtime = ref.watch(vmRuntimeProvider(vmId));
    final state = runtime.state;
    final nav = Navigator.of(context);

    if (vm == null) {
      return const ScreenFrame(
        title: 'VM details',
        body: Align(
          alignment: Alignment.topLeft,
          child: GlassCard(child: Text('This VM no longer exists.')),
        ),
      );
    }
    final off = state == VmState.poweredOff || state == VmState.error;
    final failure = runtime.lastFailure;

    Widget link(String label, IconData icon, String route, {bool on = true}) =>
        GhostButton(
          label: label,
          icon: icon,
          onPressed: on ? () => nav.pushNamed(route, arguments: vmId) : null,
        );

    return ScreenFrame(
      title: vm.name,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PillChip(
                      vmStateLabel(state),
                      pulsingDot: state == VmState.running,
                      dotColor: AppColors.success,
                    ),
                    PillChip(guestOsLabel(vm.guestOs)),
                    PillChip(guestArchLabel(vm.guestArch)),
                  ],
                ),
                const SizedBox(height: 14),
                _Line('vCPUs', '${vm.cpuCount}'),
                _Line('Memory', '${vm.memoryMiB} MiB'),
                _Line('Disks', '${vm.disks.length}'),
                _Line('Media', '${vm.media.length}'),
                if (state == VmState.error && runtime.errorReason != null)
                  _Line('Error', runtime.errorReason!),
              ],
            ),
          ).riseIn(index: 1),
          if (failure != null) ...[
            const SizedBox(height: 12),
            GlassCard(
              onTap: () => showStartFailureDialog(
                context,
                failure,
                formattedMessage: runtime.failureMessage,
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Last start failed at "${failure.step}". Tap for details.',
                    ),
                  ),
                ],
              ),
            ).riseIn(index: 2),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              link(
                'Console',
                Icons.desktop_windows_rounded,
                AppRoutes.console,
                on: !off,
              ),
              link('Edit', Icons.edit_outlined, AppRoutes.form),
              link('Media', Icons.album_outlined, AppRoutes.media),
              link('Snapshots', Icons.camera_alt_outlined, AppRoutes.snapshots),
              link('Logs', Icons.article_outlined, AppRoutes.logs),
            ],
          ).riseIn(index: 3),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
