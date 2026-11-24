/// Pure input translation: touch gestures to guest pointer events and
/// Android key codes to X11 keysyms (Req 6.2, 6.3, 6.6).
library;

/// A simple 2D size in logical units or guest pixels.
class InputSize {
  const InputSize(this.width, this.height);
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is InputSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'InputSize($width x $height)';
}

enum GestureKind {
  tap,
  longPress,
  twoFingerTap,
  singleFingerDrag,
  twoFingerVerticalDrag,
}

/// A touch gesture in view coordinates.
///
/// [x]/[y] is the gesture position (the end position for drags).
/// [dy] is the vertical drag delta in view units (two-finger drag only).
class TouchGesture {
  const TouchGesture(this.kind, this.x, this.y, {this.dy = 0});
  final GestureKind kind;
  final double x;
  final double y;
  final double dy;
}

enum PointerEventType { move, leftClick, rightClick, scroll }

/// A pointer event in guest pixel coordinates.
///
/// [scrollSteps] is positive for scrolling down, negative for up; zero for
/// non-scroll events.
class GuestPointerEvent {
  const GuestPointerEvent(this.type, this.x, this.y, {this.scrollSteps = 0});
  final PointerEventType type;
  final int x;
  final int y;
  final int scrollSteps;

  @override
  bool operator ==(Object other) =>
      other is GuestPointerEvent &&
      other.type == type &&
      other.x == x &&
      other.y == y &&
      other.scrollSteps == scrollSteps;

  @override
  int get hashCode => Object.hash(type, x, y, scrollSteps);

  @override
  String toString() => 'GuestPointerEvent($type, $x, $y, $scrollSteps)';
}

class GestureTranslator {
  const GestureTranslator._();

  /// View units of two-finger drag per scroll step.
  static const double scrollStepUnits = 40;

  static List<GuestPointerEvent> translate(
    TouchGesture gesture,
    InputSize viewSize,
    InputSize guestSize,
  ) {
    final (x, y) = _scale(gesture.x, gesture.y, viewSize, guestSize);
    switch (gesture.kind) {
      case GestureKind.singleFingerDrag:
        return [GuestPointerEvent(PointerEventType.move, x, y)];
      case GestureKind.tap:
        return [
          GuestPointerEvent(PointerEventType.move, x, y),
          GuestPointerEvent(PointerEventType.leftClick, x, y),
        ];
      case GestureKind.longPress:
      case GestureKind.twoFingerTap:
        return [
          GuestPointerEvent(PointerEventType.move, x, y),
          GuestPointerEvent(PointerEventType.rightClick, x, y),
        ];
      case GestureKind.twoFingerVerticalDrag:
        // Dragging fingers down scrolls content up (natural scrolling is
        // left to the guest); positive dy yields positive steps.
        var steps = (gesture.dy / scrollStepUnits).round();
        if (steps == 0 && gesture.dy != 0) steps = gesture.dy > 0 ? 1 : -1;
        return [
          GuestPointerEvent(PointerEventType.scroll, x, y, scrollSteps: steps),
        ];
    }
  }

  static (int, int) _scale(
    double x,
    double y,
    InputSize view,
    InputSize guest,
  ) {
    final gw = guest.width.floor();
    final gh = guest.height.floor();
    final maxX = gw > 0 ? gw - 1 : 0;
    final maxY = gh > 0 ? gh - 1 : 0;
    final sx = view.width > 0 ? x * guest.width / view.width : 0.0;
    final sy = view.height > 0 ? y * guest.height / view.height : 0.0;
    return (_clamp(sx, maxX), _clamp(sy, maxY));
  }

  static int _clamp(double v, int max) {
    if (v.isNaN) return 0;
    if (v <= 0) return 0;
    if (v >= max) return max;
    return v.floor();
  }
}

/// A key press or release carrying an X11 keysym.
class KeyEventData {
  const KeyEventData(this.keysym, {required this.down});
  final int keysym;
  final bool down;

  @override
  bool operator ==(Object other) =>
      other is KeyEventData && other.keysym == keysym && other.down == down;

  @override
  int get hashCode => Object.hash(keysym, down);

  @override
  String toString() =>
      'KeyEventData(0x${keysym.toRadixString(16)}, ${down ? 'down' : 'up'})';
}

class X11Keysyms {
  const X11Keysyms._();
  static const int backSpace = 0xff08;
  static const int tab = 0xff09;
  static const int returnKey = 0xff0d;
  static const int escape = 0xff1b;
  static const int delete = 0xffff;
  static const int left = 0xff51;
  static const int up = 0xff52;
  static const int right = 0xff53;
  static const int down = 0xff54;
  static const int space = 0x20;
  static const int shiftL = 0xffe1;
  static const int shiftR = 0xffe2;
  static const int controlL = 0xffe3;
  static const int controlR = 0xffe4;
  static const int altL = 0xffe9;
  static const int altR = 0xffea;
  static const int superL = 0xffeb;
  static const int superR = 0xffec;
  static const int f1 = 0xffbe;
}

class KeyMapper {
  const KeyMapper._();

  static Map<int, int> get _table => _fixed;

  // Android KeyEvent codes mapped to X11 keysyms.
  static const Map<int, int> _fixed = {
    // 0-9: KEYCODE_0..9 = 7..16
    7: 0x30, 8: 0x31, 9: 0x32, 10: 0x33, 11: 0x34,
    12: 0x35, 13: 0x36, 14: 0x37, 15: 0x38, 16: 0x39,
    // A-Z: KEYCODE_A..Z = 29..54 (lowercase keysyms)
    29: 0x61, 30: 0x62, 31: 0x63, 32: 0x64, 33: 0x65, 34: 0x66, 35: 0x67,
    36: 0x68, 37: 0x69, 38: 0x6a, 39: 0x6b, 40: 0x6c, 41: 0x6d, 42: 0x6e,
    43: 0x6f, 44: 0x70, 45: 0x71, 46: 0x72, 47: 0x73, 48: 0x74, 49: 0x75,
    50: 0x76, 51: 0x77, 52: 0x78, 53: 0x79, 54: 0x7a,
    // Navigation (DPAD_UP/DOWN/LEFT/RIGHT = 19..22)
    19: X11Keysyms.up, 20: X11Keysyms.down,
    21: X11Keysyms.left, 22: X11Keysyms.right,
    // Modifiers
    57: X11Keysyms.altL, 58: X11Keysyms.altR,
    59: X11Keysyms.shiftL, 60: X11Keysyms.shiftR,
    113: X11Keysyms.controlL, 114: X11Keysyms.controlR,
    117: X11Keysyms.superL, 118: X11Keysyms.superR,
    // Editing and whitespace
    61: X11Keysyms.tab, 62: X11Keysyms.space, 66: X11Keysyms.returnKey,
    67: X11Keysyms.backSpace, 111: X11Keysyms.escape, 112: X11Keysyms.delete,
    // F1..F12 = 131..142
    131: 0xffbe, 132: 0xffbf, 133: 0xffc0, 134: 0xffc1, 135: 0xffc2,
    136: 0xffc3, 137: 0xffc4, 138: 0xffc5, 139: 0xffc6, 140: 0xffc7,
    141: 0xffc8, 142: 0xffc9,
  };

  /// All Android key codes with a mapping.
  static Iterable<int> get supportedKeyCodes => _table.keys;

  /// Returns the X11 keysym for [androidKeyCode], or null if unsupported.
  static int? map(int androidKeyCode) => _table[androidKeyCode];

  /// Returns a key-down followed by a key-up for [androidKeyCode], or an empty
  /// list when the key is unsupported.
  static List<KeyEventData> press(int androidKeyCode) {
    final sym = map(androidKeyCode);
    if (sym == null) return const [];
    return [KeyEventData(sym, down: true), KeyEventData(sym, down: false)];
  }

  /// Maps a single Android key transition to a keysym event, or null.
  static KeyEventData? mapEvent(int androidKeyCode, {required bool down}) {
    final sym = map(androidKeyCode);
    return sym == null ? null : KeyEventData(sym, down: down);
  }
}

class SpecialKeys {
  const SpecialKeys._();

  /// Ctrl down, Alt down, Delete down, then releases in reverse order.
  static List<KeyEventData> get ctrlAltDel => const [
    KeyEventData(X11Keysyms.controlL, down: true),
    KeyEventData(X11Keysyms.altL, down: true),
    KeyEventData(X11Keysyms.delete, down: true),
    KeyEventData(X11Keysyms.delete, down: false),
    KeyEventData(X11Keysyms.altL, down: false),
    KeyEventData(X11Keysyms.controlL, down: false),
  ];

  static List<KeyEventData> _tap(int sym) => [
    KeyEventData(sym, down: true),
    KeyEventData(sym, down: false),
  ];

  static List<KeyEventData> get ctrl => _tap(X11Keysyms.controlL);
  static List<KeyEventData> get alt => _tap(X11Keysyms.altL);
  static List<KeyEventData> get shift => _tap(X11Keysyms.shiftL);
  static List<KeyEventData> get esc => _tap(X11Keysyms.escape);
  static List<KeyEventData> get tab => _tap(X11Keysyms.tab);

  /// Windows key on Windows guests, Command key on macOS guests.
  static List<KeyEventData> get windowsCommand => _tap(X11Keysyms.superL);
}
