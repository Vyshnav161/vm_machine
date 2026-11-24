import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/domain.dart';
import '../providers.dart';
import '../theme/theme.dart';
import 'placeholder_screens.dart' show ScreenFrame;

/// Formats a byte count as B, KB, MB, GB or TB (1024 based).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[i]}';
}

/// Returns the size in bytes of the file at a path, or null when it cannot
/// be read (missing file, `content://` URI). Tests override it.
typedef FileSizeResolver = Future<int?> Function(String path);

Future<int?> _ioFileSize(String path) async {
  if (path.contains('://')) return null;
  try {
    final f = File(path);
    return await f.exists() ? await f.length() : null;
  } on Object {
    return null;
  }
}

final fileSizeResolverProvider = Provider<FileSizeResolver>(
  (ref) => _ioFileSize,
);

/// Storage figures of one VM (Req 8.1, 8.7).
class VmStorageRow {
  const VmStorageRow({
    required this.id,
    required this.name,
    required this.virtualBytes,
    required this.actualBytes,
    required this.snapshotBytes,
    required this.copiedMediaBytes,
  });

  final String id;
  final String name;
  final int virtualBytes;
  final int actualBytes;
  final int snapshotBytes;
  final int copiedMediaBytes;

  VmStorageUsage get usage => VmStorageUsage(
    diskBytes: actualBytes,
    snapshotBytes: snapshotBytes,
    copiedMediaBytes: copiedMediaBytes,
  );
}

/// Per-VM storage rows, recomputed on every library change.
final storageRowsProvider = FutureProvider<List<VmStorageRow>>((ref) async {
  final profiles = ref.watch(vmLibraryProvider);
  final controller = ref.watch(vmManagerControllerProvider);
  final sizeOf = ref.watch(fileSizeResolverProvider);
  final rows = <VmStorageRow>[];
  for (final p in profiles) {
    var virtual = 0;
    var actual = 0;
    for (final d in p.disks) {
      virtual += d.virtualSizeBytes;
      actual += await sizeOf(d.path) ?? 0;
    }
    var copied = 0;
    for (final m in p.media) {
      if (m.copiedIntoAppStorage) copied += await sizeOf(m.path) ?? 0;
    }
    rows.add(
      VmStorageRow(
        id: p.id,
        name: p.name,
        virtualBytes: virtual,
        actualBytes: actual,
        snapshotBytes: await controller.snapshotBytes(p.id),
        copiedMediaBytes: copied,
      ),
    );
  }
  return rows;
});

/// Storage overview (Req 8.1, 8.7). Also used as a tab.
class StorageOverviewScreen extends ConsumerWidget {
  const StorageOverviewScreen({super.key, this.tab = false});

  final bool tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(storageRowsProvider);
    return ScreenFrame(
      title: 'Storage',
      showBack: !tab,
      bottomPadding: tab ? 100 : 24,
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Align(
          alignment: Alignment.topLeft,
          child: GlassCard(child: Text('Could not read storage: $e')),
        ),
        data: (list) => _Content(rows: list),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.rows});

  final List<VmStorageRow> rows;

  @override
  Widget build(BuildContext context) {
    final total = StorageOverview.total(rows.map((r) => r.usage));
    final disks = rows.fold<int>(0, (s, r) => s + r.actualBytes);
    final snaps = rows.fold<int>(0, (s, r) => s + r.snapshotBytes);
    final media = rows.fold<int>(0, (s, r) => s + r.copiedMediaBytes);
    final theme = Theme.of(context).textTheme;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total used', style: theme.labelLarge),
              const SizedBox(height: 4),
              GradientText(
                formatBytes(total),
                style: theme.displaySmall,
                maxLines: 1,
              ).copyKey('storage-total'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PillChip('Disks ${formatBytes(disks)}'),
                  PillChip('Snapshots ${formatBytes(snaps)}'),
                  PillChip('Copied media ${formatBytes(media)}'),
                ],
              ),
            ],
          ),
        ).riseIn(index: 1),
        const SizedBox(height: 14),
        if (rows.isEmpty)
          const GlassCard(
            child: Text('No virtual machines yet.'),
          ).riseIn(index: 2),
        for (var i = 0; i < rows.length; i++) ...[
          _VmRow(row: rows[i]).riseIn(index: i + 2),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

extension on Widget {
  Widget copyKey(String key) => KeyedSubtree(key: ValueKey(key), child: this);
}

class _VmRow extends StatelessWidget {
  const _VmRow({required this.row});

  final VmStorageRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.name, style: theme.titleMedium),
          const SizedBox(height: 10),
          _Line('Virtual size', formatBytes(row.virtualBytes)),
          _Line('Used on device', formatBytes(row.actualBytes)),
          _Line('Snapshots', formatBytes(row.snapshotBytes)),
          _Line('Copied media', formatBytes(row.copiedMediaBytes)),
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
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
