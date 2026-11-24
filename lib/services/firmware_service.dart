import 'package:flutter/services.dart';

/// Source of the bundled QEMU share directory and UEFI firmware
/// (`assets/qemu`). Channel: `vm/host`.
abstract class FirmwareSource {
  /// Version marker of the bundled files, or null when none are bundled.
  Future<String?> bundledVersion();

  /// Replaces [dest] with a copy of the bundled files.
  Future<void> extractTo(String dest);
}

class ChannelFirmwareSource implements FirmwareSource {
  final MethodChannel _channel;
  ChannelFirmwareSource([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('vm/host');

  @override
  Future<String?> bundledVersion() =>
      _channel.invokeMethod<String>('firmwareVersion');

  @override
  Future<void> extractTo(String dest) =>
      _channel.invokeMethod<void>('extractFirmware', {'dest': dest});
}

/// Copies the bundled firmware into [targetDir] once per bundled version.
///
/// The copied directory carries the bundled `VERSION` file, so a later app
/// version with a different marker recopies, and an unchanged one does not.
class FirmwareInstaller {
  FirmwareInstaller({required this.source, required this.readInstalledVersion});

  final FirmwareSource source;

  /// Reads the `VERSION` file inside the target directory; null when absent.
  final Future<String?> Function(String targetDir) readInstalledVersion;

  /// Returns true when files were copied, false when already current or when
  /// no firmware is bundled.
  Future<bool> ensureInstalled(String targetDir) async {
    final bundled = await source.bundledVersion();
    if (bundled == null) return false;
    final installed = await readInstalledVersion(targetDir);
    if (installed?.trim() == bundled.trim()) return false;
    await source.extractTo(targetDir);
    return true;
  }
}
