import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme/theme.dart';

/// Shows whether All-files access is granted and offers the grant action.
/// QEMU opens in-place media by real path, which needs this permission.
///
/// When [problem] is set, it is shown as a message under the status, and
/// [onCopyInstead] adds a button that copies the file into app storage.
class AllFilesAccessCard extends ConsumerStatefulWidget {
  const AllFilesAccessCard({super.key, this.problem, this.onCopyInstead});

  final String? problem;
  final VoidCallback? onCopyInstead;

  @override
  ConsumerState<AllFilesAccessCard> createState() => _AllFilesAccessCardState();
}

class _AllFilesAccessCardState extends ConsumerState<AllFilesAccessCard>
    with WidgetsBindingObserver {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The user returns from the system settings screen through a resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await ref
        .read(vmManagerControllerProvider)
        .hasAllFilesAccess();
    if (mounted) setState(() => _granted = granted);
  }

  Future<void> _grant() async {
    final opened = await ref
        .read(vmManagerControllerProvider)
        .requestAllFilesAccess();
    if (!mounted) return;
    if (!opened) {
      AppToast.show(
        context,
        'Could not open the settings screen. Enable All-files access for '
        'this app in system Settings.',
        error: true,
      );
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    if (granted == null) return const SizedBox.shrink();
    final problem = widget.problem;
    if (granted && problem == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: AppColors.muted),
            SizedBox(width: 8),
            Expanded(child: Text('All-files access granted')),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    problem ??
                        'All-files access is off. Files used in place cannot '
                            'be opened by the VM until you grant it.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!granted)
                  GhostButton(
                    label: 'Grant All-files access',
                    icon: Icons.lock_open_rounded,
                    onPressed: _grant,
                  ),
                if (widget.onCopyInstead != null)
                  GhostButton(
                    label: 'Copy into app storage instead',
                    icon: Icons.copy_rounded,
                    onPressed: widget.onCopyInstead,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
