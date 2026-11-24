import 'package:flutter/services.dart';

import '../domain/domain.dart';

/// Host condition updates. Channel: `vm/hostSignals`.
abstract class HostSignalService {
  /// One [HostSignals] per change; fields not in the event are null.
  Stream<HostSignals> get signals;
}

/// Maps a `vm/hostSignals` event map. Unknown thermal names become null.
HostSignals parseHostSignals(Map<Object?, Object?> m) {
  ThermalStatus? thermal;
  final t = m['thermal'];
  if (t is String) {
    for (final s in ThermalStatus.values) {
      if (s.name == t) thermal = s;
    }
  }
  return HostSignals(
    thermal: thermal,
    batteryPercent: (m['batteryPercent'] as num?)?.toInt(),
    charging: m['charging'] as bool?,
    trimMemoryLevel: (m['trimMemoryLevel'] as num?)?.toInt(),
    freeStorageBytes: (m['freeStorageBytes'] as num?)?.toInt(),
    networkConnected: m['networkConnected'] as bool?,
  );
}

class ChannelHostSignalService implements HostSignalService {
  final EventChannel _channel;
  Stream<HostSignals>? _stream;
  ChannelHostSignalService([EventChannel? channel])
    : _channel = channel ?? const EventChannel('vm/hostSignals');

  @override
  Stream<HostSignals> get signals => _stream ??= _channel
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => parseHostSignals(e as Map<Object?, Object?>))
      .asBroadcastStream();
}
