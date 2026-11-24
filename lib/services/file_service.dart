import 'package:flutter/services.dart';

/// Result of `pickMedia`.
class PickedMedia {
  final String uri;
  final String name;
  final int? size;
  final bool supported;
  const PickedMedia({
    required this.uri,
    required this.name,
    this.size,
    required this.supported,
  });
}

/// Result of `copyMedia`.
class CopyResult {
  final bool ok;
  final String? path;
  final int? bytes;

  /// `no_space`, `cancelled` or `io` when [ok] is false.
  final String? error;
  final int? required;
  final int? available;
  final String? message;
  const CopyResult({
    required this.ok,
    this.path,
    this.bytes,
    this.error,
    this.required,
    this.available,
    this.message,
  });
}

class RemovableVolume {
  final String description;
  final String path;
  final int? freeBytes;
  const RemovableVolume({
    required this.description,
    required this.path,
    this.freeBytes,
  });
}

/// Storage Access Framework and file helpers. Channel: `vm/files`.
abstract class FileService {
  /// Null when the user cancels.
  Future<PickedMedia?> pickMedia();

  /// Whether All-files access (`MANAGE_EXTERNAL_STORAGE`) is granted. QEMU
  /// runs as a child process and opens media by real path, which needs it.
  Future<bool> hasAllFilesAccess();

  /// Opens the system screen for All-files access. False when none opens.
  Future<bool> requestAllFilesAccess();

  /// Real, readable file path behind a picked `content://` URI, or null when
  /// it cannot be mapped (cloud provider, no access, file gone).
  Future<String?> resolveRealPath(String uri);

  /// Progress arrives as `CopyProgressEvent` on `EngineService.events`.
  Future<CopyResult> copyMedia(String uri, String dest);
  Future<void> cancelCopy(String dest);
  Future<int?> freeSpace(String path);
  Future<List<RemovableVolume>> removableVolumes();
  Future<bool> shareLogs(String path);

  /// https only.
  Future<bool> openUrl(String url);
}

class ChannelFileService implements FileService {
  final MethodChannel _channel;
  ChannelFileService([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('vm/files');

  @override
  Future<PickedMedia?> pickMedia() async {
    final m = await _channel.invokeMapMethod<String, Object?>('pickMedia');
    if (m == null) return null;
    return PickedMedia(
      uri: m['uri']! as String,
      name: m['name'] as String? ?? '',
      size: (m['size'] as num?)?.toInt(),
      supported: m['supported'] as bool? ?? false,
    );
  }

  @override
  Future<bool> hasAllFilesAccess() async =>
      (await _channel.invokeMethod<bool>('hasAllFilesAccess')) ?? false;

  @override
  Future<bool> requestAllFilesAccess() async =>
      (await _channel.invokeMethod<bool>('requestAllFilesAccess')) ?? false;

  @override
  Future<String?> resolveRealPath(String uri) =>
      _channel.invokeMethod<String>('resolveRealPath', {'uri': uri});

  @override
  Future<CopyResult> copyMedia(String uri, String dest) async {
    final m = await _channel.invokeMapMethod<String, Object?>('copyMedia', {
      'uri': uri,
      'dest': dest,
    });
    return CopyResult(
      ok: m?['ok'] as bool? ?? false,
      path: m?['path'] as String?,
      bytes: (m?['bytes'] as num?)?.toInt(),
      error: m?['error'] as String?,
      required: (m?['required'] as num?)?.toInt(),
      available: (m?['available'] as num?)?.toInt(),
      message: m?['message'] as String?,
    );
  }

  @override
  Future<void> cancelCopy(String dest) =>
      _channel.invokeMethod('cancelCopy', {'dest': dest});

  @override
  Future<int?> freeSpace(String path) async =>
      (await _channel.invokeMethod<num>('freeSpace', {'path': path}))?.toInt();

  @override
  Future<List<RemovableVolume>> removableVolumes() async {
    final list = await _channel.invokeListMethod<Object?>('removableVolumes');
    return [
      for (final raw in list ?? const <Object?>[])
        if (raw is Map)
          RemovableVolume(
            description: raw['description'] as String? ?? '',
            path: raw['path']! as String,
            freeBytes: (raw['freeBytes'] as num?)?.toInt(),
          ),
    ];
  }

  @override
  Future<bool> shareLogs(String path) async =>
      (await _channel.invokeMethod<bool>('shareLogs', {'path': path})) ?? false;

  @override
  Future<bool> openUrl(String url) async =>
      (await _channel.invokeMethod<bool>('openUrl', {'url': url})) ?? false;
}
