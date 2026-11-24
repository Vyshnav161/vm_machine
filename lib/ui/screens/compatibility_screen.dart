import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/domain.dart';
import '../../services/services.dart';
import '../providers.dart';
import '../theme/theme.dart';

/// Host compatibility report (Req 1.2 to 1.7).
///
/// Shows the detected host values (`Unknown` when detection failed), one
/// entry per guest OS and architecture with its acceleration mode and
/// warnings, and a refresh action that repeats detection.
class CompatibilityScreen extends ConsumerStatefulWidget {
  const CompatibilityScreen({super.key, this.tab = false});

  /// True when shown as a tab behind the floating nav bar.
  final bool tab;

  @override
  ConsumerState<CompatibilityScreen> createState() =>
      _CompatibilityScreenState();
}

class _CompatibilityScreenState extends ConsumerState<CompatibilityScreen> {
  CompatibilityReport? _report;
  EngineStatus? _engine;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(refresh: false);
  }

  Future<void> _load({required bool refresh}) async {
    setState(() => _loading = true);
    final controller = ref.read(vmManagerControllerProvider);
    CompatibilityReport? report;
    try {
      report = refresh
          ? await controller.refreshCapabilities()
          : await controller.detectCapabilities();
    } catch (_) {
      report = null;
    }
    final engine = await controller.engineStatus();
    if (!mounted) return;
    setState(() {
      _engine = engine;
      _report = report ?? _report;
      _loading = false;
    });
    if (report == null) {
      AppToast.show(context, 'Detection failed. Try again.', error: true);
    } else if (refresh) {
      AppToast.show(context, 'Host capabilities refreshed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, widget.tab ? 100 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (!widget.tab)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  Expanded(
                    child: GradientText(
                      'Compatibility',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ).riseIn(),
              const SizedBox(height: 16),
              Expanded(
                child: report == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          _HostCard(
                            host: report.host,
                            engine: _engine,
                          ).riseIn(index: 1),
                          const SizedBox(height: 16),
                          for (var i = 0; i < report.entries.length; i++) ...[
                            _EntryCard(
                              entry: report.entries[i],
                            ).riseIn(index: 2 + i),
                            const SizedBox(height: 12),
                          ],
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: PrimaryButton(
                              label: _loading ? 'Refreshing...' : 'Refresh',
                              icon: Icons.refresh_rounded,
                              onPressed: _loading
                                  ? null
                                  : () => _load(refresh: true),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String osLabel(GuestOs os) => switch (os) {
  GuestOs.linux => 'Linux',
  GuestOs.windows => 'Windows',
  GuestOs.macos => 'macOS',
};

String archLabel(GuestArch arch) => switch (arch) {
  GuestArch.arm64 => 'ARM64',
  GuestArch.x86_64 => 'x86_64',
};

String modeLabel(AccelerationMode mode) => switch (mode) {
  AccelerationMode.hardwareVirtualization => 'Hardware virtualization',
  AccelerationMode.softwareEmulation => 'Software emulation',
};

String warningLabel(CompatibilityWarning w) => switch (w) {
  CompatibilityWarning.reducedPerformance =>
    'Performance is substantially reduced',
  CompatibilityWarning.notRecommendedLowRam =>
    'Not recommended: this device has less than 4 GB of RAM',
};

String _bytes(int b) {
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  return b >= gib
      ? '${(b / gib).toStringAsFixed(1)} GB'
      : '${(b / mib).toStringAsFixed(0)} MB';
}

String _detected<T>(Detected<T> d, String Function(T) fmt) => switch (d) {
  Known<T>(:final value) => fmt(value),
  Unknown<T>() => 'Unknown',
};

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host, this.engine});
  final HostCapabilities host;
  final EngineStatus? engine;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, Detected<Object>)>[
      ('CPU architecture', host.arch),
      ('Total RAM', host.totalRamBytes),
      ('Free storage', host.freeStorageBytes),
      ('CPU cores', host.cpuCores),
      ('Hardware virtualization', host.hardwareVirtualization),
    ];
    String fmt(String label, Object v) => switch (label) {
      'CPU architecture' => archLabel(v as GuestArch),
      'Total RAM' || 'Free storage' => _bytes(v as int),
      'Hardware virtualization' => (v as bool) ? 'Available' : 'Unavailable',
      _ => '$v',
    };
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This device', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ),
                  Text(
                    _detected<Object>(value, (v) => fmt(label, v)),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: value is Unknown
                          ? AppColors.warning
                          : AppColors.text,
                    ),
                  ),
                ],
              ),
            ),
          if (engine != null) _EngineRow(status: engine!),
        ],
      ),
    );
  }
}

/// "QEMU engine" row: installed, partially installed or not installed.
class _EngineRow extends StatelessWidget {
  const _EngineRow({required this.status});

  final EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final installed = status.installed;
    final text = installed
        ? 'Installed'
        : status.partial
        ? 'Partially installed'
        : 'Not installed';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'QEMU engine',
                  style: TextStyle(color: AppColors.muted),
                ),
              ),
              Text(
                text,
                key: const Key('engine-status'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: installed ? AppColors.text : AppColors.warning,
                ),
              ),
            ],
          ),
          if (!installed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Build the engine with tools/build-qemu-android.sh '
                '(see tools/README.md), then rebuild the app.',
                key: const Key('engine-status-help'),
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});
  final CompatibilityEntry entry;

  @override
  Widget build(BuildContext context) {
    final mode = entry.mode;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${osLabel(entry.os)} on ${archLabel(entry.arch)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (mode != null)
                PillChip(
                  modeLabel(mode),
                  icon: mode == AccelerationMode.hardwareVirtualization
                      ? Icons.bolt_rounded
                      : Icons.memory_rounded,
                )
              else
                const PillChip('Not runnable', icon: Icons.block_rounded),
            ],
          ),
          if (entry.blockedReason != null) ...[
            const SizedBox(height: 8),
            Text(
              entry.blockedReason!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ],
          for (final w in entry.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      warningLabel(w),
                      style: const TextStyle(color: AppColors.warning),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
