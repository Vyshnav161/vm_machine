import 'enums.dart';
import 'vm_profile.dart';

/// Detects installation media built for a different CPU architecture than the
/// VM (Req 2.1, 4.1, 12.1). Pure and based only on the media file name.
class ArchMismatchDetector {
  const ArchMismatchDetector._();

  static final RegExp _x86 = RegExp(
    r'(?<![a-z0-9])(amd64|x86[_-]?64|x64)(?![a-z0-9])',
  );
  static final RegExp _arm = RegExp(
    r'(?<![a-z0-9])(arm64|aarch64)(?![a-z0-9])',
  );

  /// The architecture a file name clearly indicates, or null when it has no
  /// indicator or indicates both.
  static GuestArch? detectFromName(String name) {
    final n = name.toLowerCase();
    final x = _x86.hasMatch(n);
    final a = _arm.hasMatch(n);
    if (x == a) return null;
    return x ? GuestArch.x86_64 : GuestArch.arm64;
  }

  /// The architecture indicated by [media] (using [MediaRef.label], which
  /// prefers the display name over an opaque path), or null if unclear.
  static GuestArch? detect(Iterable<MediaRef> media) {
    final found = <GuestArch>{};
    for (final m in media) {
      if (m.kind != MediaKind.iso && m.kind != MediaKind.img) continue;
      final d = detectFromName(m.label);
      if (d != null) found.add(d);
    }
    return found.length == 1 ? found.first : null;
  }

  static String _label(GuestArch a) =>
      a == GuestArch.arm64 ? 'ARM64' : 'x86_64';

  /// A warning text when the media clearly targets another architecture than
  /// [vmArch]; null otherwise.
  static String? hint(Iterable<MediaRef> media, GuestArch vmArch) {
    final d = detect(media);
    if (d == null || d == vmArch) return null;
    return 'The attached media looks like an ${_label(d)} image, but this VM '
        'is ${_label(vmArch)}. It may not boot. Use matching media or change '
        'the VM architecture.';
  }
}
