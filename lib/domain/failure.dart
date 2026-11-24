import 'dart:typed_data';

/// A failed step in the VM start sequence (Req 12.1).
class StartFailure {
  const StartFailure(this.step, this.cause);

  /// QEMU libraries are not installed (`engine_missing`). [missing] names the
  /// absent libraries.
  factory StartFailure.engineMissing(List<String> missing) => StartFailure(
    engineMissingStep,
    FailureMessage.engineMissingText(missing),
  );

  static const engineMissingStep = 'QEMU engine not installed';

  final String step;
  final String cause;

  bool get isEngineMissing => step == engineMissingStep;

  @override
  bool operator ==(Object other) =>
      other is StartFailure && other.step == step && other.cause == cause;

  @override
  int get hashCode => Object.hash(step, cause);

  @override
  String toString() => 'StartFailure(step: $step, cause: $cause)';
}

/// Typed platform or engine error shown instead of raw exceptions.
class VmError {
  const VmError({required this.step, required this.cause, this.hint});

  final String step;
  final String cause;
  final String? hint;

  StartFailure toStartFailure() => StartFailure(step, cause);

  @override
  bool operator ==(Object other) =>
      other is VmError &&
      other.step == step &&
      other.cause == cause &&
      other.hint == hint;

  @override
  int get hashCode => Object.hash(step, cause, hint);

  @override
  String toString() => 'VmError(step: $step, cause: $cause, hint: $hint)';
}

/// Formats start failures for display (Req 12.1, 12.6).
class FailureMessage {
  const FailureMessage._();

  static const String slowBootHint =
      'Boot may take several minutes under software emulation.';

  static String engineMissingText(List<String> missing) {
    final libs = missing.isEmpty ? '' : '\nMissing: ${missing.join(', ')}';
    return 'QEMU engine not installed. This build does not include the QEMU '
        'binaries.$libs\n'
        'Setup:\n'
        '1. Build them with tools/build-qemu-android.sh (see tools/README.md).\n'
        '2. Put the .so files in android/app/src/main/jniLibs/arm64-v8a.\n'
        '3. Rebuild and reinstall the app.';
  }

  static String format(
    StartFailure f, {
    required bool crossArch,
    String? archHint,
  }) {
    if (f.isEngineMissing) return f.cause;
    var msg = 'Failed at step "${f.step}": ${f.cause}';
    if (crossArch) msg = '$msg\n$slowBootHint';
    if (archHint != null) msg = '$msg\n$archHint';
    return msg;
  }
}

/// Keeps log files bounded to the newest bytes (Req 12.5).
class LogRotator {
  const LogRotator._();

  /// Production log limit: 10 MiB.
  static const int defaultMaxBytes = 10 * 1024 * 1024;

  static Uint8List rotate(
    Uint8List existing,
    Uint8List appended,
    int maxBytes,
  ) {
    if (maxBytes <= 0) return Uint8List(0);
    final total = existing.length + appended.length;
    final keep = total < maxBytes ? total : maxBytes;
    final out = Uint8List(keep);
    final skip = total - keep;
    var o = 0;
    if (skip < existing.length) {
      final part = existing.sublist(skip);
      out.setRange(0, part.length, part);
      o = part.length;
      out.setRange(o, keep, appended);
    } else {
      out.setRange(0, keep, appended, skip - existing.length);
    }
    return out;
  }
}
