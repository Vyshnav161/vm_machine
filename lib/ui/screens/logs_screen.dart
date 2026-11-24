import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/domain.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'placeholder_screens.dart' show ScreenFrame;

/// Log text of one VM. Invalidate to reload.
final vmLogProvider = FutureProvider.autoDispose.family<String, String>(
  (ref, id) => ref.watch(vmManagerControllerProvider).viewLog(id),
);

/// Log viewer with share action (Req 12.3, 12.4).
class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key, required this.vmId});

  final String vmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(vmLogProvider(vmId));
    return ScreenFrame(
      title: 'Logs',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GhostButton(
                  label: 'Refresh',
                  icon: Icons.refresh_rounded,
                  onPressed: () => ref.invalidate(vmLogProvider(vmId)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  label: 'Share',
                  icon: Icons.ios_share_rounded,
                  onPressed: () => _share(context, ref),
                ),
              ),
            ],
          ).riseIn(index: 1),
          const SizedBox(height: 14),
          Expanded(
            child: GlassCard(
              child: log.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Could not read the log: $e'),
                data: (text) => text.isEmpty
                    ? const Text(
                        'The log is empty.',
                        style: TextStyle(color: AppColors.muted),
                      )
                    : SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                          text,
                          key: const Key('log-text'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
              ),
            ).riseIn(index: 2),
          ),
        ],
      ),
    );
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final r = await ref.read(vmManagerControllerProvider).shareLog(vmId);
    if (!context.mounted || r.ok) return;
    AppToast.show(
      context,
      r.message ?? 'The log could not be shared.',
      error: true,
    );
  }
}

/// Startup error dialog with step, cause and hint (Req 12.1, 12.6).
Future<void> showStartFailureDialog(
  BuildContext context,
  StartFailure failure, {
  String? formattedMessage,
}) {
  final hint = (formattedMessage ?? '').contains(FailureMessage.slowBootHint)
      ? FailureMessage.slowBootHint
      : null;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        failure.isEngineMissing
            ? 'QEMU engine not installed'
            : 'VM failed to start',
      ),
      content: failure.isEngineMissing
          ? SingleChildScrollView(child: Text(failure.cause))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Step: ${failure.step}'),
                const SizedBox(height: 6),
                Text('Cause: ${failure.cause}'),
                if (hint != null) ...[
                  const SizedBox(height: 6),
                  Text(hint, style: const TextStyle(color: AppColors.muted)),
                ],
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
