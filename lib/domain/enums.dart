/// Core enums and the [Detected] wrapper. Pure Dart only.
library;

enum GuestOs { linux, windows, macos }

enum GuestArch { arm64, x86_64 }

enum AccelerationMode { softwareEmulation, hardwareVirtualization }

enum VmState { poweredOff, starting, running, paused, stopping, error }

/// User-mode NAT is the only mode in the first release (Req 11.1).
enum NetworkMode { nat }

enum MediaStatus { present, missing }

/// Installation media and disk formats accepted by the app (Req 4.1).
enum MediaKind { iso, img, qcow2, vhdx }

/// A value that may have failed detection (Req 1.7).
sealed class Detected<T> {
  const Detected();

  /// The value when [Known], otherwise null.
  T? get valueOrNull => switch (this) {
    Known<T>(:final value) => value,
    Unknown<T>() => null,
  };
}

class Known<T> extends Detected<T> {
  final T value;
  const Known(this.value);

  @override
  bool operator ==(Object other) => other is Known<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Known, value);

  @override
  String toString() => 'Known($value)';
}

class Unknown<T> extends Detected<T> {
  const Unknown();

  @override
  bool operator ==(Object other) => other is Unknown<T>;

  @override
  int get hashCode => (Unknown).hashCode;

  @override
  String toString() => 'Unknown';
}
