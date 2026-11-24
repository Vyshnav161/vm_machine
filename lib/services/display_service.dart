import 'package:flutter/services.dart';

class MirrorStatus {
  final bool externalConnected;
  final bool mirroring;
  final String? id;
  const MirrorStatus({
    required this.externalConnected,
    required this.mirroring,
    this.id,
  });
}

class TextureSize {
  final int width;
  final int height;
  const TextureSize(this.width, this.height);
}

/// Guest display and input. Channel: `vm/display`.
abstract class DisplayService {
  /// Returns the Flutter texture id.
  Future<int> createTexture(String id, {String? socketPath});

  /// Guest coordinates; [buttons] is the RFB button mask.
  Future<bool> sendPointer(String id, int x, int y, int buttons);
  Future<bool> sendKey(String id, int keysym, bool down);
  Future<bool> screenshot(String id, String path);
  Future<TextureSize> textureSize(String id);
  Future<void> disposeTexture(String id);
  Future<MirrorStatus> mirrorStatus();

  /// False when there is no external display or no VNC socket.
  Future<bool> mirrorStart(String id);
  Future<void> mirrorStop();
}

class ChannelDisplayService implements DisplayService {
  final MethodChannel _channel;
  ChannelDisplayService([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('vm/display');

  Future<bool> _bool(String m, Map<String, Object?> a) async =>
      (await _channel.invokeMethod<bool>(m, a)) ?? false;

  @override
  Future<int> createTexture(String id, {String? socketPath}) async =>
      (await _channel.invokeMethod<int>('createTexture', {
        'id': id,
        'socketPath': ?socketPath,
      }))!;

  @override
  Future<bool> sendPointer(String id, int x, int y, int buttons) =>
      _bool('sendPointer', {'id': id, 'x': x, 'y': y, 'buttons': buttons});

  @override
  Future<bool> sendKey(String id, int keysym, bool down) =>
      _bool('sendKey', {'id': id, 'keysym': keysym, 'down': down});

  @override
  Future<bool> screenshot(String id, String path) =>
      _bool('screenshot', {'id': id, 'path': path});

  @override
  Future<TextureSize> textureSize(String id) async {
    final m = await _channel.invokeMapMethod<String, Object?>('textureSize', {
      'id': id,
    });
    return TextureSize(
      (m?['width'] as num?)?.toInt() ?? 0,
      (m?['height'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> disposeTexture(String id) =>
      _channel.invokeMethod('disposeTexture', {'id': id});

  @override
  Future<MirrorStatus> mirrorStatus() async {
    final m = await _channel.invokeMapMethod<String, Object?>('mirrorStatus');
    return MirrorStatus(
      externalConnected: m?['externalConnected'] as bool? ?? false,
      mirroring: m?['mirroring'] as bool? ?? false,
      id: m?['id'] as String?,
    );
  }

  @override
  Future<bool> mirrorStart(String id) => _bool('mirrorStart', {'id': id});

  @override
  Future<void> mirrorStop() => _channel.invokeMethod('mirrorStop');
}
