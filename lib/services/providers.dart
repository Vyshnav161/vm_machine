import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'display_service.dart';
import 'engine_service.dart';
import 'file_service.dart';
import 'host_probe_service.dart';
import 'host_signal_service.dart';

/// Channel-backed defaults; tests override these with fakes.
final hostProbeServiceProvider = Provider<HostProbeService>(
  (ref) => ChannelHostProbeService(),
);
final engineServiceProvider = Provider<EngineService>(
  (ref) => ChannelEngineService(),
);
final fileServiceProvider = Provider<FileService>(
  (ref) => ChannelFileService(),
);
final displayServiceProvider = Provider<DisplayService>(
  (ref) => ChannelDisplayService(),
);
final hostSignalServiceProvider = Provider<HostSignalService>(
  (ref) => ChannelHostSignalService(),
);
