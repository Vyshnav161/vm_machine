import 'package:flutter/services.dart';

import '../domain/domain.dart';

/// Detects host capabilities (Req 1.1). Channel: `vm/host`.
abstract class HostProbeService {
  Future<HostCapabilities> probe();

  /// True when POST_NOTIFICATIONS is granted (always true below Android 13).
  Future<bool> requestNotificationPermission();
}

class ChannelHostProbeService implements HostProbeService {
  final MethodChannel _channel;
  ChannelHostProbeService([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('vm/host');

  @override
  Future<HostCapabilities> probe() async {
    final m = await _channel.invokeMapMethod<String, Object?>('probe');
    return parseHostCapabilities(m ?? const {});
  }

  @override
  Future<bool> requestNotificationPermission() async =>
      (await _channel.invokeMethod<bool>('requestNotificationPermission')) ??
      false;
}

/// Maps the `probe()` payload; null or unrecognised values become [Unknown].
HostCapabilities parseHostCapabilities(Map<String, Object?> m) {
  Detected<int> intOf(String k) {
    final v = m[k];
    return v is num ? Known(v.toInt()) : const Unknown();
  }

  final Detected<GuestArch> arch = switch (m['arch']) {
    'arm64' => const Known(GuestArch.arm64),
    'x86_64' => const Known(GuestArch.x86_64),
    _ => const Unknown(),
  };
  final virt = m['virt'];
  return HostCapabilities(
    arch: arch,
    totalRamBytes: intOf('totalRam'),
    freeStorageBytes: intOf('freeStorage'),
    cpuCores: intOf('cores'),
    hardwareVirtualization: virt is bool ? Known(virt) : const Unknown(),
  );
}
