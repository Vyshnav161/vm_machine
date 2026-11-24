import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/domain.dart';
import '../../services/services.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'all_files_access_card.dart';
import 'placeholder_screens.dart' show ScreenFrame;

/// Attach and detach installation media of one VM (Req 4.1, 4.3, 4.4, 4.7).
class MediaAttachScreen extends ConsumerStatefulWidget {
  const MediaAttachScreen({super.key, required this.vmId});

  final String vmId;

  @override
  ConsumerState<MediaAttachScreen> createState() => _MediaAttachScreenState();
}

class _MediaAttachScreenState extends ConsumerState<MediaAttachScreen> {
  StreamSubscription<Object>? _sub;
  int? _percent;
  bool _busy = false;
  String? _rejection;
  PickedMedia? _offerPicked;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(vmManagerControllerProvider)
        .copyProgress
        .listen((p) => setState(() => _percent = p.percent));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _attach() async {
    final controller = ref.read(vmManagerControllerProvider);
    final picked = await controller.pickMedia();
    if (picked == null || !mounted) return;
    final copy = await _askCopy(picked);
    if (copy == null || !mounted) return;
    await _attachPicked(picked, copy: copy);
  }

  Future<void> _attachPicked(PickedMedia picked, {required bool copy}) async {
    final controller = ref.read(vmManagerControllerProvider);
    setState(() {
      _busy = true;
      _rejection = null;
      _offerPicked = null;
      _percent = copy ? 0 : null;
    });
    // In-place checks are cheap and have no side effects, so run them first
    // to offer the copy fallback. A copy goes straight to attachMedia.
    if (!copy) {
      final prep = await controller.prepareMedia(
        picked,
        vmId: widget.vmId,
        copy: false,
      );
      if (!mounted) return;
      if (!prep.ok && prep.copyWouldHelp) {
        setState(() {
          _busy = false;
          _percent = null;
          _rejection = prep.message;
          _offerPicked = picked;
        });
        return;
      }
    }
    final r = await controller.attachMedia(widget.vmId, picked, copy: copy);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _percent = null;
      _rejection = r.ok ? null : r.message;
    });
    AppToast.show(
      context,
      r.ok ? 'Attached ${picked.name}' : (r.message ?? 'Could not attach.'),
      error: !r.ok,
    );
  }

  Future<bool?> _askCopy(PickedMedia picked) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(picked.name, overflow: TextOverflow.ellipsis),
      content: const Text(
        'Use the file where it is, or copy it into app storage. '
        'Copying needs free space for the whole file.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Use in place'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Copy'),
        ),
      ],
    ),
  );

  Future<void> _detach(MediaRef m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Detach media?'),
        content: const Text(
          'The reference is removed from this VM. The file is not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Detach'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await ref
        .read(vmManagerControllerProvider)
        .detachMedia(widget.vmId, m.path);
    if (!mounted) return;
    AppToast.show(
      context,
      r.ok ? 'Media detached' : (r.message ?? 'Could not detach.'),
      error: !r.ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(vmProfileProvider(widget.vmId));
    final state = ref.watch(vmStateProvider(widget.vmId));
    final off = state == VmState.poweredOff;
    final media = profile?.media ?? const <MediaRef>[];
    return ScreenFrame(
      title: 'Media',
      body: profile == null
          ? const Align(
              alignment: Alignment.topLeft,
              child: GlassCard(child: Text('This VM no longer exists.')),
            )
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                PrimaryButton(
                  label: 'Attach media',
                  icon: Icons.attach_file_rounded,
                  onPressed: off && !_busy ? _attach : null,
                ).riseIn(index: 1),
                if (!off)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Power the VM off to change its media.',
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Supported: ${MediaFilter.supportedExtensions.join(', ')}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (_percent != null) ...[
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Copying… $_percent%'),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _percent! / 100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                AllFilesAccessCard(
                  problem: _offerPicked == null ? null : _rejection,
                  onCopyInstead: _offerPicked == null || _busy
                      ? null
                      : () => _attachPicked(_offerPicked!, copy: true),
                ),
                if (_rejection != null && _offerPicked == null) ...[
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: AppColors.danger,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_rejection!)),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (media.isEmpty)
                  const GlassCard(child: Text('No media attached.')),
                for (var i = 0; i < media.length; i++) ...[
                  _MediaTile(
                    media: media[i],
                    onDetach: off && !_busy ? () => _detach(media[i]) : null,
                  ).riseIn(index: i + 2),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.media, required this.onDetach});

  final MediaRef media;
  final VoidCallback? onDetach;

  @override
  Widget build(BuildContext context) {
    final name = media.label;
    return GlassCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? media.path : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    PillChip(media.kind.name.toUpperCase()),
                    PillChip(
                      media.copiedIntoAppStorage ? 'Copied' : 'In place',
                    ),
                    if (media.status == MediaStatus.missing)
                      const PillChip(
                        'Missing',
                        icon: Icons.warning_amber_rounded,
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Detach',
            icon: const Icon(Icons.link_off_rounded),
            onPressed: onDetach,
          ),
        ],
      ),
    );
  }
}
