import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'controller/file_ops.dart';
import 'controller/vm_layout.dart';
import 'controller/vm_manager_controller.dart';
import 'data/vm_repository.dart';
import 'services/engine_service.dart';
import 'services/file_service.dart';
import 'services/firmware_service.dart';
import 'services/host_probe_service.dart';
import 'services/host_signal_service.dart';
import 'ui/app_router.dart';
import 'ui/providers.dart';
import 'ui/theme/theme.dart';

/// Builds the real controller: profiles under the app documents directory,
/// channel-backed services, plain `dart:io` file operations and the
/// `vm/hostSignals` stream (Req 10.1).
///
/// Loads the library, probes the host (Req 1.1), marks VMs that died with the
/// previous app process as `Error` (Req 5.8), and starts host-signal handling,
/// which the controller does as soon as it is constructed with the service.
Future<VmManagerController> createController({
  required Directory documents,
  HostProbeService? hostProbe,
  EngineService? engine,
  FileService? files,
  HostSignalService? hostSignals,
  FirmwareInstaller? firmware,
}) async {
  final layout = VmLayout(documents.path);
  // Copy the bundled QEMU share directory and UEFI firmware once per version.
  // A failure only breaks VM start, which reports the missing file.
  try {
    await (firmware ??
            FirmwareInstaller(
              source: ChannelFirmwareSource(),
              readInstalledVersion: (dir) async {
                final f = File('$dir/VERSION');
                return await f.exists() ? f.readAsString() : null;
              },
            ))
        .ensureInstalled(layout.qemuShareDir);
  } on Object catch (e) {
    debugPrint('Firmware install failed: $e');
  }
  final controller = VmManagerController(
    repository: FileVmRepository(documents),
    engine: engine ?? ChannelEngineService(),
    files: files ?? ChannelFileService(),
    hostProbe: hostProbe ?? ChannelHostProbeService(),
    layout: layout,
    pathExists: (path) async =>
        await FileSystemEntity.type(path) != FileSystemEntityType.notFound,
    fileOps: const IoFileOps(),
    hostSignals: hostSignals ?? ChannelHostSignalService(),
  );
  await controller.load();
  await controller.reconcileStaleRuntime();
  // Unreadable values stay Unknown and never block; the report is shown on the
  // Host tab and is cached for the first start.
  await controller.detectCapabilities();
  return controller;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final documents = await getApplicationDocumentsDirectory();
  final controller = await createController(documents: documents);
  runApp(
    ProviderScope(
      overrides: [vmManagerControllerProvider.overrideWithValue(controller)],
      child: const VmMachineApp(),
    ),
  );
  // Ask for notification permission once the first frame is up, so the system
  // dialog does not cover a blank screen. A denial only hides the status
  // notification; VMs still run.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await ChannelHostProbeService().requestNotificationPermission();
    } on PlatformException {
      // Ignore: the permission is optional.
    }
  });
}

class VmMachineApp extends StatelessWidget {
  const VmMachineApp({super.key, this.animateBackground = true});

  final bool animateBackground;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VM Machine',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      initialRoute: AppRoutes.home,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      builder: (context, child) =>
          AppBackground(animate: animateBackground, child: child!),
    );
  }
}
