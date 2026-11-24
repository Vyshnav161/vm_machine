import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../controller/vm_manager_controller.dart';
import '../../domain/domain.dart';
import '../../services/display_service.dart';
import '../../services/providers.dart';
import '../providers.dart';
import '../theme/theme.dart';

/// Live stats of one VM. Restarts when the VM state changes, because the
/// controller's stream ends when the VM is not running or paused (Req 7.2).
final vmStatsProvider = StreamProvider.autoDispose.family<VmStats, String>((
  ref,
  id,
) {
  ref.watch(vmStateProvider(id));
  return ref.watch(vmManagerControllerProvider).statsStream(id);
});

/// Last chosen bottom-bar mode (true: trackpad), kept for the app session.
bool lastTrackpadMode = false;

/// Trackpad pointer gain: the drag delta is multiplied by this factor. Fast
/// moves (more than 8 view units per event) get extra gain.
double trackpadGain(double deltaLength) => deltaLength > 8 ? 3.0 : 2.0;

/// VM console: guest display, touch and keyboard input, stats overlay and
/// power controls (Req 5.1 to 5.6, 6.1 to 6.8, 7.2, 7.3).
class VmConsoleScreen extends ConsumerStatefulWidget {
  const VmConsoleScreen({super.key, required this.vmId});
  final String vmId;

  @override
  ConsumerState<VmConsoleScreen> createState() => _VmConsoleScreenState();
}

class _VmConsoleScreenState extends ConsumerState<VmConsoleScreen>
    with WidgetsBindingObserver {
  static const _longPress = Duration(milliseconds: 500);
  static const _twoFingerTapWindow = Duration(milliseconds: 300);
  static const _slop = 12.0;

  late final DisplayService _display = ref.read(displayServiceProvider);
  final _kbFocus = FocusNode();
  final _kbController = TextEditingController(text: _sentinel);
  static const _sentinel = '\u200b';

  int? _textureId;
  bool _creating = false;
  bool _waitingForDisplay = false;
  Timer? _retryTimer;
  InputSize _guest = const InputSize(0, 0);
  InputSize _view = const InputSize(1, 1);
  bool _mirroring = false;
  bool _busy = false;
  String _kbPrev = _sentinel;

  // Touch tracking.
  final Map<int, Offset> _touches = {};
  final Map<int, Offset> _touchStart = {};
  Offset? _lastPrimary;
  DateTime _downAt = DateTime.now();
  Timer? _longPressTimer;
  bool _moved = false;
  bool _longFired = false;
  bool _twoFinger = false;
  double _scrollAcc = 0;

  // Trackpad mode. The mode choice outlives the screen for the app session.
  bool _trackpad = lastTrackpadMode;
  bool _fullscreen = false;
  double? _cx;
  double? _cy;
  int _heldButtons = 0;

  // Hardware keyboard: keysym sent on key down, reused on key up.
  final Map<PhysicalKeyboardKey, int> _heldKeys = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshMirror());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_fullscreen) _applySystemChrome(false);
    _longPressTimer?.cancel();
    _retryTimer?.cancel();
    _kbFocus.dispose();
    _kbController.dispose();
    if (_textureId != null) unawaited(_display.disposeTexture(widget.vmId));
    super.dispose();
  }

  /// Rotation changes the layout only; the engine is never touched (Req 6.5).
  @override
  void didChangeMetrics() => unawaited(_refreshGuestSize());

  bool _live(VmState s) => s == VmState.running || s == VmState.paused;

  Future<void> _ensureTexture() async {
    if (_textureId != null || _creating) return;
    _creating = true;
    try {
      final controller = ref.read(vmManagerControllerProvider);
      final id = await _display.createTexture(
        widget.vmId,
        socketPath: controller.layout.pathsFor(widget.vmId).vncSocketPath,
      );
      if (!mounted) {
        unawaited(_display.disposeTexture(widget.vmId));
        return;
      }
      setState(() {
        _textureId = id;
        _waitingForDisplay = false;
      });
      await _refreshGuestSize();
    } on PlatformException catch (e) {
      // The guest may still be booting, so keep waiting and retry instead of
      // showing a dead end. Report the first failure only.
      if (mounted) {
        if (!_waitingForDisplay) {
          AppToast.show(context, e.message ?? e.code, error: true);
        }
        setState(() => _waitingForDisplay = true);
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) unawaited(_ensureTexture());
        });
      }
    } finally {
      _creating = false;
    }
  }

  Future<void> _releaseTexture() async {
    if (_textureId == null) return;
    setState(() => _textureId = null);
    try {
      await _display.disposeTexture(widget.vmId);
    } on PlatformException {
      // The texture dies with the engine anyway.
    }
  }

  Future<void> _refreshGuestSize() async {
    if (_textureId == null) return;
    try {
      final s = await _display.textureSize(widget.vmId);
      if (mounted && s.width > 0 && s.height > 0) {
        setState(
          () => _guest = InputSize(s.width.toDouble(), s.height.toDouble()),
        );
      }
    } on PlatformException {
      // Keep the last known size.
    }
  }

  Future<void> _refreshMirror() async {
    try {
      final m = await _display.mirrorStatus();
      if (mounted) {
        setState(() => _mirroring = m.mirroring && m.id == widget.vmId);
      }
    } on PlatformException {
      // Leave the toggle off.
    }
  }

  // ---------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------

  InputSize get _guestOrView => _guest.width > 0 ? _guest : _view;

  void _send(int x, int y, int buttons) {
    unawaited(
      _display.sendPointer(widget.vmId, x, y, buttons).catchError((_) => false),
    );
  }

  void _sendKey(KeyEventData k) {
    unawaited(
      _display.sendKey(widget.vmId, k.keysym, k.down).catchError((_) => false),
    );
  }

  Future<void> _sendKeys(List<KeyEventData> keys) async {
    for (final k in keys) {
      _sendKey(k);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  /// RFB button masks: left 1, middle 2, right 4, wheel up 8, wheel down 16.
  Future<void> _apply(List<GuestPointerEvent> events) async {
    for (final e in events) {
      switch (e.type) {
        case PointerEventType.move:
          _send(e.x, e.y, 0);
        case PointerEventType.leftClick:
          _send(e.x, e.y, 1);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          _send(e.x, e.y, 0);
        case PointerEventType.rightClick:
          _send(e.x, e.y, 4);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          _send(e.x, e.y, 0);
        case PointerEventType.scroll:
          final mask = e.scrollSteps > 0 ? 16 : 8;
          for (var i = 0; i < e.scrollSteps.abs(); i++) {
            _send(e.x, e.y, mask);
            _send(e.x, e.y, 0);
          }
      }
    }
  }

  void _gesture(GestureKind kind, Offset pos, {double dy = 0}) {
    unawaited(
      _apply(
        GestureTranslator.translate(
          TouchGesture(kind, pos.dx, pos.dy, dy: dy),
          _view,
          _guestOrView,
        ),
      ),
    );
  }

  void _onDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      _mouse(e.localPosition, _rfbButtons(e.buttons));
      return;
    }
    if (_touches.isEmpty) {
      _downAt = DateTime.now();
      _moved = false;
      _longFired = false;
      _twoFinger = false;
      _scrollAcc = 0;
    }
    _touches[e.pointer] = e.localPosition;
    _touchStart[e.pointer] = e.localPosition;
    _lastPrimary = e.localPosition;
    if (_touches.length >= 2) {
      _twoFinger = true;
      _longPressTimer?.cancel();
    } else {
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPress, () {
        if (!_moved && !_twoFinger && _touches.length == 1) {
          _longFired = true;
          _gesture(GestureKind.longPress, _lastPrimary!);
        }
      });
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      _mouse(e.localPosition, _rfbButtons(e.buttons));
      return;
    }
    final prev = _touches[e.pointer];
    if (prev == null) return;
    _touches[e.pointer] = e.localPosition;
    final start = _touchStart[e.pointer]!;
    if ((e.localPosition - start).distance > _slop) {
      if (!_moved) _longPressTimer?.cancel();
      _moved = true;
    }
    if (_twoFinger) {
      if (_touches.length == 2 && e.pointer == _touches.keys.first) {
        _scrollAcc += e.localPosition.dy - prev.dy;
        if (_scrollAcc.abs() >= GestureTranslator.scrollStepUnits) {
          final mid = (_touches.values.first + _touches.values.last) / 2;
          _gesture(GestureKind.twoFingerVerticalDrag, mid, dy: _scrollAcc);
          _scrollAcc = 0;
        }
      }
    } else if (_moved) {
      _lastPrimary = e.localPosition;
      _gesture(GestureKind.singleFingerDrag, e.localPosition);
    }
  }

  void _onUp(PointerUpEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      _mouse(e.localPosition, 0);
      return;
    }
    _longPressTimer?.cancel();
    final wasTwo = _twoFinger;
    _touches.remove(e.pointer);
    _touchStart.remove(e.pointer);
    if (_touches.isNotEmpty) return;
    final quick = DateTime.now().difference(_downAt) < _twoFingerTapWindow;
    if (wasTwo) {
      if (!_moved && quick) _gesture(GestureKind.twoFingerTap, e.localPosition);
    } else if (!_moved && !_longFired) {
      _gesture(GestureKind.tap, e.localPosition);
    }
    _twoFinger = false;
  }

  void _onCancel(PointerCancelEvent e) {
    _longPressTimer?.cancel();
    _touches.remove(e.pointer);
    _touchStart.remove(e.pointer);
    if (_touches.isEmpty) _twoFinger = false;
  }

  // External mouse: Flutter bit 1 primary, 2 secondary, 4 middle.
  int _rfbButtons(int flutter) =>
      (flutter & kPrimaryButton != 0 ? 1 : 0) |
      (flutter & kMiddleMouseButton != 0 ? 2 : 0) |
      (flutter & kSecondaryButton != 0 ? 4 : 0);

  void _mouse(Offset pos, int buttons) {
    final ev = GestureTranslator.translate(
      TouchGesture(GestureKind.singleFingerDrag, pos.dx, pos.dy),
      _view,
      _guestOrView,
    ).first;
    _send(ev.x, ev.y, buttons);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
      final ev = GestureTranslator.translate(
        TouchGesture(
          GestureKind.twoFingerVerticalDrag,
          e.localPosition.dx,
          e.localPosition.dy,
          dy: e.scrollDelta.dy.sign * GestureTranslator.scrollStepUnits,
        ),
        _view,
        _guestOrView,
      );
      unawaited(_apply(ev));
    }
  }

  static final Map<LogicalKeyboardKey, int> _keysyms = {
    LogicalKeyboardKey.backspace: X11Keysyms.backSpace,
    LogicalKeyboardKey.tab: X11Keysyms.tab,
    LogicalKeyboardKey.enter: X11Keysyms.returnKey,
    LogicalKeyboardKey.numpadEnter: X11Keysyms.returnKey,
    LogicalKeyboardKey.escape: X11Keysyms.escape,
    LogicalKeyboardKey.delete: X11Keysyms.delete,
    LogicalKeyboardKey.arrowLeft: X11Keysyms.left,
    LogicalKeyboardKey.arrowUp: X11Keysyms.up,
    LogicalKeyboardKey.arrowRight: X11Keysyms.right,
    LogicalKeyboardKey.arrowDown: X11Keysyms.down,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.shiftLeft: X11Keysyms.shiftL,
    LogicalKeyboardKey.shiftRight: X11Keysyms.shiftR,
    LogicalKeyboardKey.controlLeft: X11Keysyms.controlL,
    LogicalKeyboardKey.controlRight: X11Keysyms.controlR,
    LogicalKeyboardKey.altLeft: X11Keysyms.altL,
    LogicalKeyboardKey.altRight: X11Keysyms.altR,
    LogicalKeyboardKey.metaLeft: X11Keysyms.superL,
    LogicalKeyboardKey.metaRight: X11Keysyms.superR,
    for (var i = 0; i < 12; i++)
      [
        LogicalKeyboardKey.f1,
        LogicalKeyboardKey.f2,
        LogicalKeyboardKey.f3,
        LogicalKeyboardKey.f4,
        LogicalKeyboardKey.f5,
        LogicalKeyboardKey.f6,
        LogicalKeyboardKey.f7,
        LogicalKeyboardKey.f8,
        LogicalKeyboardKey.f9,
        LogicalKeyboardKey.f10,
        LogicalKeyboardKey.f11,
        LogicalKeyboardKey.f12,
      ][i]: X11Keysyms.f1 + i,
  };

  static int? _runeToKeysym(int rune) {
    if (rune < 0x20) return null;
    if (rune < 0x100) return rune;
    return 0x01000000 + rune;
  }

  int? _keysymFor(KeyEvent e) {
    final fixed = _keysyms[e.logicalKey];
    if (fixed != null) return fixed;
    final ch = e.character;
    if (ch != null && ch.isNotEmpty) return _runeToKeysym(ch.runes.first);
    final label = e.logicalKey.keyLabel;
    if (label.runes.length == 1) {
      return _runeToKeysym(label.toLowerCase().runes.first);
    }
    return null;
  }

  /// External keyboard forwarding (Req 6.3).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_textureId == null) return KeyEventResult.ignored;
    if (e is KeyUpEvent) {
      final sym = _heldKeys.remove(e.physicalKey);
      if (sym == null) return KeyEventResult.ignored;
      _sendKey(KeyEventData(sym, down: false));
      return KeyEventResult.handled;
    }
    // With the soft keyboard field focused, text keys arrive through it.
    if (_kbFocus.hasFocus) {
      final k = e.logicalKey;
      final textKey =
          (e.character?.isNotEmpty ?? false) ||
          k == LogicalKeyboardKey.backspace ||
          k == LogicalKeyboardKey.enter;
      if (textKey) return KeyEventResult.ignored;
    }
    final sym = _keysymFor(e);
    if (sym == null) return KeyEventResult.ignored;
    _heldKeys[e.physicalKey] = sym;
    _sendKey(KeyEventData(sym, down: true));
    return KeyEventResult.handled;
  }

  void _toggleSoftKeyboard() {
    if (_kbFocus.hasFocus) {
      _kbFocus.unfocus();
    } else {
      _kbFocus.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }
  }

  /// Soft keyboard text is diffed against the previous value: removed
  /// characters become Backspace, added ones are typed.
  void _onSoftText(String text) {
    var common = 0;
    while (common < _kbPrev.length &&
        common < text.length &&
        _kbPrev[common] == text[common]) {
      common++;
    }
    for (var i = common; i < _kbPrev.length; i++) {
      unawaited(_sendKeys(KeyMapper.press(67)));
    }
    for (final r in text.substring(common).runes) {
      final sym = _runeToKeysym(r);
      if (sym != null) {
        unawaited(
          _sendKeys([
            KeyEventData(sym, down: true),
            KeyEventData(sym, down: false),
          ]),
        );
      }
    }
    _kbPrev = text;
    if (text.length > 64) {
      _kbController.value = const TextEditingValue(
        text: _sentinel,
        selection: TextSelection.collapsed(offset: 1),
      );
      _kbPrev = _sentinel;
    }
  }

  // ---------------------------------------------------------------------
  // Trackpad (relative movement, absolute tablet coordinates)
  // ---------------------------------------------------------------------

  void _applySystemChrome(bool full) {
    unawaited(
      SystemChrome.setPreferredOrientations(
        full
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  void _setFullscreen(bool on) {
    if (_fullscreen == on) return;
    _applySystemChrome(on);
    setState(() => _fullscreen = on);
    // Rotation changes the texture size the input mapping depends on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshGuestSize());
    });
  }

  void _setTrackpad(bool on) {
    lastTrackpadMode = on;
    setState(() => _trackpad = on);
  }

  (int, int) _cursor() {
    final g = _guestOrView;
    _cx ??= g.width / 2;
    _cy ??= g.height / 2;
    final maxX = g.width > 1 ? g.width - 1 : 0.0;
    final maxY = g.height > 1 ? g.height - 1 : 0.0;
    _cx = _cx!.clamp(0.0, maxX);
    _cy = _cy!.clamp(0.0, maxY);
    return (_cx!.floor(), _cy!.floor());
  }

  void _trackpadMove(Offset delta) {
    _cursor();
    final gain = trackpadGain(delta.distance);
    _cx = _cx! + delta.dx * gain;
    _cy = _cy! + delta.dy * gain;
    final (x, y) = _cursor();
    _send(x, y, _heldButtons);
  }

  Future<void> _trackpadClick(int mask) async {
    unawaited(HapticFeedback.lightImpact());
    final (x, y) = _cursor();
    _send(x, y, mask);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _send(x, y, 0);
  }

  void _trackpadDragStart() {
    unawaited(HapticFeedback.mediumImpact());
    _heldButtons = 1;
    final (x, y) = _cursor();
    _send(x, y, 1);
  }

  void _trackpadDragEnd() {
    if (_heldButtons == 0) return;
    _heldButtons = 0;
    final (x, y) = _cursor();
    _send(x, y, 0);
  }

  void _trackpadScroll(int steps) {
    final (x, y) = _cursor();
    final mask = steps > 0 ? 16 : 8;
    for (var i = 0; i < steps.abs(); i++) {
      _send(x, y, mask);
      _send(x, y, 0);
    }
  }

  /// Key bar press: key down then key up through [KeyMapper].
  void _pressAndroidKey(int androidKeyCode) {
    for (final k in KeyMapper.press(androidKeyCode)) {
      _sendKey(k);
    }
  }

  void _showControls(VmProfile profile) {
    final c = ref.read(vmManagerControllerProvider);
    final id = widget.vmId;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.toastFill,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        // Close the sheet first, then run the action.
        VoidCallback act(VoidCallback f) => () {
          Navigator.of(ctx).pop();
          f();
        };
        return _ControlsSheet(
          vmId: id,
          busy: _busy,
          mirroring: _mirroring,
          onStart: act(() => unawaited(_run(() => c.start(id)))),
          onPause: act(() => unawaited(_run(() => c.pause(id)))),
          onResume: act(() => unawaited(_run(() => c.resume(id)))),
          onShutdown: act(() => unawaited(_run(() => c.shutdown(id)))),
          onRestart: act(() => unawaited(_run(() => c.restart(id)))),
          onForceStop: act(() => unawaited(_confirmForceStop())),
          onKeyboard: act(_toggleSoftKeyboard),
          onSpecialKeys: act(() => _showSpecialKeys(profile)),
          onScreenshot: act(() => unawaited(_screenshot(profile))),
          onMirror: act(() => unawaited(_toggleMirror())),
        );
      },
    );
  }

  void _showSpecialKeys(VmProfile profile) {
    final winLabel = profile.guestOs == GuestOs.macos ? 'Command' : 'Windows';
    final items = <(String, List<KeyEventData>)>[
      ('Ctrl+Alt+Del', SpecialKeys.ctrlAltDel),
      ('Ctrl', SpecialKeys.ctrl),
      ('Alt', SpecialKeys.alt),
      ('Shift', SpecialKeys.shift),
      ('Esc', SpecialKeys.esc),
      ('Tab', SpecialKeys.tab),
      (winLabel, SpecialKeys.windowsCommand),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.toastFill,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const GradientText(
                'Special keys',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final (label, keys) in items)
                    GhostButton(
                      label: label,
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        unawaited(_sendKeys(keys));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------

  Future<void> _screenshot(VmProfile profile) async {
    final controller = ref.read(vmManagerControllerProvider);
    final dir = controller.layout.screenshotsDir;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final safe = profile.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final path = p.join(dir, '${safe}_$stamp.png');
    try {
      await controller.fileOps.ensureDir(dir);
      final ok = await _display.screenshot(widget.vmId, path);
      if (!mounted) return;
      AppToast.show(
        context,
        ok ? 'Screenshot saved to $path' : 'Could not save the screenshot.',
        error: !ok,
      );
    } on Object catch (e) {
      if (mounted) AppToast.show(context, _msg(e), error: true);
    }
  }

  Future<void> _toggleMirror() async {
    try {
      if (_mirroring) {
        await _display.mirrorStop();
        if (mounted) setState(() => _mirroring = false);
        return;
      }
      final status = await _display.mirrorStatus();
      if (!status.externalConnected) {
        if (mounted) AppToast.show(context, 'No external display connected.');
        return;
      }
      final ok = await _display.mirrorStart(widget.vmId);
      if (!mounted) return;
      setState(() => _mirroring = ok);
      if (!ok) {
        AppToast.show(
          context,
          'Could not start the external display.',
          error: true,
        );
      }
    } on Object catch (e) {
      if (mounted) AppToast.show(context, _msg(e), error: true);
    }
  }

  String _msg(Object e) =>
      e is PlatformException ? (e.message ?? e.code) : e.toString();

  Future<void> _run(Future<CommandResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await action();
      if (mounted && !r.ok) {
        AppToast.show(context, r.message ?? 'Command failed.', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmForceStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.toastFill,
        title: const Text('Force stop?'),
        content: const Text(
          'The VM process is killed immediately. Unsaved data in the guest '
          'can be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Force stop',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final c = ref.read(vmManagerControllerProvider);
    await _run(() => c.forceStop(widget.vmId, confirmed: true));
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(vmProfileProvider(widget.vmId));
    final runtime = ref.watch(vmRuntimeProvider(widget.vmId));
    if (profile == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: GhostButton(
              label: 'VM not found. Go back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      );
    }

    final live = _live(runtime.state);
    if (live && _textureId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureTexture());
      });
    } else if (!live && _textureId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_releaseTexture());
      });
    }

    final stats = ref.watch(vmStatsProvider(widget.vmId)).asData?.value;
    final state = runtime.state;

    final keyBar = _KeyBar(
      side: _fullscreen,
      onFullscreen: () => _setFullscreen(!_fullscreen),
      enabled: live,
      onKey: _pressAndroidKey,
      onMore: () => _showControls(profile),
      trackpad: _trackpad,
      onToggleMode: () => _setTrackpad(!_trackpad),
      onPadMove: _trackpadMove,
      onPadClick: (m) => unawaited(_trackpadClick(m)),
      onPadDragStart: _trackpadDragStart,
      onPadDragEnd: _trackpadDragEnd,
      onPadScroll: _trackpadScroll,
    );

    final display = _DisplayArea(
      textureId: live ? _textureId : null,
      guest: _guest,
      state: state,
      errorText: runtime.errorReason ?? runtime.failureMessage,
      waiting: _waitingForDisplay,
      stats: live ? stats : null,
      onViewSize: (s) => _view = s,
      onDown: _onDown,
      onMove: _onMove,
      onUp: _onUp,
      onCancel: _onCancel,
      onSignal: _onSignal,
      onHover: (e) {
        if (e.kind == PointerDeviceKind.mouse) _mouse(e.localPosition, 0);
      },
    );

    final Widget content = _fullscreen
        ? Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(child: display),
                const SizedBox(width: 8),
                SizedBox(width: 210, child: keyBar),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                _TopBar(profile: profile, state: state, stats: stats).riseIn(),
                const SizedBox(height: 10),
                Expanded(child: display),
                const SizedBox(height: 8),
                keyBar.riseIn(index: 1),
              ],
            ),
          );

    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _setFullscreen(false);
      },
      child: Scaffold(
        body: SafeArea(
          child: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: Stack(
              children: [
                content,
                // Hidden field that carries soft keyboard input.
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: 0,
                    child: SizedBox(
                      width: 1,
                      height: 1,
                      child: TextField(
                        focusNode: _kbFocus,
                        controller: _kbController,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.visiblePassword,
                        onChanged: _onSoftText,
                        onSubmitted: (_) {
                          unawaited(_sendKeys(KeyMapper.press(66)));
                          _kbFocus.requestFocus();
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.profile,
    required this.state,
    required this.stats,
  });
  final VmProfile profile;
  final VmState state;
  final VmStats? stats;

  @override
  Widget build(BuildContext context) {
    final running = state == VmState.running;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: GradientText(
            profile.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(width: 8),
        if (stats?.crossArch ?? false) ...[
          const PillChip('Cross-arch emulation', icon: Icons.memory_rounded),
          const SizedBox(width: 6),
        ],
        PillChip(
          _stateLabel(state),
          pulsingDot: running,
          dotColor: AppColors.success,
        ),
      ],
    );
  }
}

String _stateLabel(VmState s) => switch (s) {
  VmState.poweredOff => 'Powered off',
  VmState.starting => 'Starting',
  VmState.running => 'Running',
  VmState.paused => 'Paused',
  VmState.stopping => 'Stopping',
  VmState.error => 'Error',
};

class _DisplayArea extends StatelessWidget {
  const _DisplayArea({
    required this.textureId,
    required this.guest,
    required this.state,
    required this.errorText,
    required this.waiting,
    required this.stats,
    required this.onViewSize,
    required this.onDown,
    required this.onMove,
    required this.onUp,
    required this.onCancel,
    required this.onSignal,
    required this.onHover,
  });

  final int? textureId;
  final InputSize guest;
  final VmState state;
  final String? errorText;
  final bool waiting;
  final VmStats? stats;
  final void Function(InputSize) onViewSize;
  final void Function(PointerDownEvent) onDown;
  final void Function(PointerMoveEvent) onMove;
  final void Function(PointerUpEvent) onUp;
  final void Function(PointerCancelEvent) onCancel;
  final void Function(PointerSignalEvent) onSignal;
  final void Function(PointerHoverEvent) onHover;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (textureId != null)
              Center(
                child: AspectRatio(
                  aspectRatio: guest.width > 0 && guest.height > 0
                      ? guest.width / guest.height
                      : 16 / 9,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      onViewSize(InputSize(box.maxWidth, box.maxHeight));
                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: onDown,
                        onPointerMove: onMove,
                        onPointerUp: onUp,
                        onPointerCancel: onCancel,
                        onPointerSignal: onSignal,
                        onPointerHover: onHover,
                        child: Texture(textureId: textureId!),
                      );
                    },
                  ),
                ),
              )
            else
              _Placeholder(
                state: state,
                errorText: errorText,
                waiting: waiting,
              ),
            if (stats != null)
              Positioned(
                left: 10,
                top: 10,
                child: IgnorePointer(child: PillChip(stats!.text)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.state,
    required this.errorText,
    this.waiting = false,
  });
  final bool waiting;
  final VmState state;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final text = switch (state) {
      VmState.poweredOff => 'The VM is powered off.',
      VmState.starting => 'Starting. This can take several minutes.',
      VmState.stopping => 'Stopping.',
      VmState.error => errorText ?? 'The VM stopped with an error.',
      _ when waiting =>
        'Waiting for the display. The guest may still be booting.',
      _ => 'Connecting to the display.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: state == VmState.error ? AppColors.danger : AppColors.muted,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

/// Compact bottom bar. Keys mode: Esc, arrows, Enter. Trackpad mode: a
/// touchpad with Left and Right click buttons. Both have a mode toggle and a
/// menu button.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.enabled,
    required this.onKey,
    required this.onMore,
    required this.trackpad,
    required this.onToggleMode,
    required this.onPadMove,
    required this.onPadClick,
    required this.onPadDragStart,
    required this.onPadDragEnd,
    required this.onPadScroll,
    required this.onFullscreen,
    this.side = false,
  });

  /// True in the fullscreen side panel (vertical layout).
  final bool side;
  final VoidCallback onFullscreen;
  final bool enabled;

  /// Receives an Android key code (see [KeyMapper]); sends down then up.
  final void Function(int androidKeyCode) onKey;
  final VoidCallback onMore;
  final bool trackpad;
  final VoidCallback onToggleMode;
  final void Function(Offset delta) onPadMove;

  /// Receives the RFB button mask (1 left, 4 right).
  final void Function(int mask) onPadClick;
  final VoidCallback onPadDragStart;
  final VoidCallback onPadDragEnd;
  final void Function(int steps) onPadScroll;

  @override
  Widget build(BuildContext context) {
    Widget key(
      String label,
      int code, {
      bool repeat = false,
      Key? k,
      IconData? icon,
    }) => _RepeatKey(
      key: k,
      label: label,
      icon: icon,
      enabled: enabled,
      repeat: repeat,
      onPress: () => onKey(code),
    );

    const compact = BoxConstraints(minWidth: 36, minHeight: 40);
    final toggle = IconButton(
      key: const Key('key-mode'),
      constraints: compact,
      padding: EdgeInsets.zero,
      tooltip: trackpad ? 'Show keys' : 'Show trackpad',
      icon: Icon(
        trackpad ? Icons.keyboard_alt_outlined : Icons.touch_app_outlined,
      ),
      onPressed: onToggleMode,
    );
    final fullscreenBtn = IconButton(
      key: Key(side ? 'key-exit-fullscreen' : 'key-fullscreen'),
      constraints: compact,
      padding: EdgeInsets.zero,
      tooltip: side ? 'Exit fullscreen' : 'Fullscreen',
      icon: Icon(
        side ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
      ),
      onPressed: onFullscreen,
    );
    final more = IconButton(
      key: const Key('key-more'),
      constraints: compact,
      padding: EdgeInsets.zero,
      tooltip: 'Controls',
      icon: const Icon(Icons.more_horiz_rounded),
      onPressed: onMore,
    );

    if (side) {
      final controls = Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [toggle, more, fullscreenBtn],
      );
      return GlassCard(
        radius: AppRadii.card,
        padding: const EdgeInsets.all(8),
        child: trackpad
            ? Column(
                children: [
                  Expanded(
                    child: _TrackpadSurface(
                      enabled: enabled,
                      onMove: onPadMove,
                      onClick: onPadClick,
                      onDragStart: onPadDragStart,
                      onDragEnd: onPadDragEnd,
                      onScroll: onPadScroll,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _RepeatKey(
                          key: const Key('pad-left-click'),
                          label: 'Left',
                          enabled: enabled,
                          repeat: false,
                          onPress: () => onPadClick(1),
                        ),
                      ),
                      Expanded(
                        child: _RepeatKey(
                          key: const Key('pad-right-click'),
                          label: 'Right',
                          enabled: enabled,
                          repeat: false,
                          onPress: () => onPadClick(4),
                        ),
                      ),
                    ],
                  ),
                  controls,
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      key('Esc', 111, k: const Key('key-esc')),
                      key('Enter', 66, k: const Key('key-enter')),
                    ],
                  ),
                  key(
                    '',
                    19,
                    repeat: true,
                    k: const Key('key-up'),
                    icon: Icons.keyboard_arrow_up_rounded,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      key(
                        '',
                        21,
                        repeat: true,
                        k: const Key('key-left'),
                        icon: Icons.keyboard_arrow_left_rounded,
                      ),
                      key(
                        '',
                        20,
                        repeat: true,
                        k: const Key('key-down'),
                        icon: Icons.keyboard_arrow_down_rounded,
                      ),
                      key(
                        '',
                        22,
                        repeat: true,
                        k: const Key('key-right'),
                        icon: Icons.keyboard_arrow_right_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  controls,
                ],
              ),
      );
    }

    if (trackpad) {
      return GlassCard(
        radius: AppRadii.card,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 180,
              child: _TrackpadSurface(
                enabled: enabled,
                onMove: onPadMove,
                onClick: onPadClick,
                onDragStart: onPadDragStart,
                onDragEnd: onPadDragEnd,
                onScroll: onPadScroll,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _RepeatKey(
                    key: const Key('pad-left-click'),
                    label: 'Left click',
                    enabled: enabled,
                    repeat: false,
                    onPress: () => onPadClick(1),
                  ),
                ),
                toggle,
                Expanded(
                  child: _RepeatKey(
                    key: const Key('pad-right-click'),
                    label: 'Right click',
                    enabled: enabled,
                    repeat: false,
                    onPress: () => onPadClick(4),
                  ),
                ),
                more,
                fullscreenBtn,
              ],
            ),
          ],
        ),
      );
    }

    return GlassCard(
      radius: AppRadii.pill,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          key('Esc', 111, k: const Key('key-esc')),
          const SizedBox(width: 4),
          const Spacer(),
          key(
            '',
            21,
            repeat: true,
            k: const Key('key-left'),
            icon: Icons.keyboard_arrow_left_rounded,
          ),
          key(
            '',
            19,
            repeat: true,
            k: const Key('key-up'),
            icon: Icons.keyboard_arrow_up_rounded,
          ),
          key(
            '',
            20,
            repeat: true,
            k: const Key('key-down'),
            icon: Icons.keyboard_arrow_down_rounded,
          ),
          key(
            '',
            22,
            repeat: true,
            k: const Key('key-right'),
            icon: Icons.keyboard_arrow_right_rounded,
          ),
          const Spacer(),
          key('Enter', 66, k: const Key('key-enter')),
          const SizedBox(width: 4),
          toggle,
          more,
          fullscreenBtn,
        ],
      ),
    );
  }
}

/// Touchpad: drag moves, tap clicks, two-finger tap right-clicks, two-finger
/// vertical drag scrolls, long-press then drag holds the left button.
class _TrackpadSurface extends StatefulWidget {
  const _TrackpadSurface({
    required this.enabled,
    required this.onMove,
    required this.onClick,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onScroll,
  });
  final bool enabled;
  final void Function(Offset delta) onMove;
  final void Function(int mask) onClick;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final void Function(int steps) onScroll;

  @override
  State<_TrackpadSurface> createState() => _TrackpadSurfaceState();
}

class _TrackpadSurfaceState extends State<_TrackpadSurface> {
  static const _longPress = Duration(milliseconds: 500);
  static const _tapWindow = Duration(milliseconds: 300);
  static const _slop = 12.0;

  final Map<int, Offset> _start = {};
  Timer? _timer;
  DateTime _downAt = DateTime.now();
  bool _moved = false;
  bool _twoFinger = false;
  bool _dragging = false;
  double _scrollAcc = 0;

  @override
  void dispose() {
    _timer?.cancel();
    if (_dragging) widget.onDragEnd();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled) return;
    if (_start.isEmpty) {
      _downAt = DateTime.now();
      _moved = false;
      _twoFinger = false;
      _dragging = false;
      _scrollAcc = 0;
    }
    _start[e.pointer] = e.localPosition;
    _timer?.cancel();
    if (_start.length >= 2) {
      _twoFinger = true;
    } else {
      _timer = Timer(_longPress, () {
        if (!_moved && !_twoFinger && _start.length == 1) {
          _dragging = true;
          widget.onDragStart();
        }
      });
    }
  }

  void _move(PointerMoveEvent e) {
    final start = _start[e.pointer];
    if (start == null) return;
    if ((e.localPosition - start).distance > _slop) {
      if (!_moved && !_dragging) _timer?.cancel();
      _moved = true;
    }
    if (_twoFinger) {
      if (e.pointer == _start.keys.first) {
        _scrollAcc += e.delta.dy;
        if (_scrollAcc.abs() >= GestureTranslator.scrollStepUnits) {
          final steps = (_scrollAcc / GestureTranslator.scrollStepUnits)
              .truncate();
          widget.onScroll(steps);
          _scrollAcc -= steps * GestureTranslator.scrollStepUnits;
        }
      }
    } else {
      widget.onMove(e.delta);
    }
  }

  void _up(PointerUpEvent e) {
    if (_start.remove(e.pointer) == null) return;
    _timer?.cancel();
    if (_start.isNotEmpty) return;
    final quick = DateTime.now().difference(_downAt) < _tapWindow;
    if (_dragging) {
      _dragging = false;
      widget.onDragEnd();
    } else if (_twoFinger) {
      if (!_moved && quick) widget.onClick(4);
    } else if (!_moved) {
      widget.onClick(1);
    }
    _twoFinger = false;
  }

  void _cancel(PointerCancelEvent e) {
    _start.remove(e.pointer);
    _timer?.cancel();
    if (_start.isEmpty) {
      if (_dragging) widget.onDragEnd();
      _dragging = false;
      _twoFinger = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.enabled ? 1 : 0.45,
      child: Listener(
        key: const Key('trackpad'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(AppRadii.card - 4),
            border: Border.all(color: AppColors.line),
          ),
          child: const Center(
            child: Icon(Icons.mouse_outlined, size: 28, color: AppColors.muted),
          ),
        ),
      ),
    );
  }
}

/// One key. Fires on press, and while held when [repeat] is set.
class _RepeatKey extends StatefulWidget {
  const _RepeatKey({
    super.key,
    required this.label,
    required this.enabled,
    required this.repeat,
    required this.onPress,
    this.icon,
  });
  final String label;
  final IconData? icon;
  final bool enabled;
  final bool repeat;
  final VoidCallback onPress;

  @override
  State<_RepeatKey> createState() => _RepeatKeyState();
}

class _RepeatKeyState extends State<_RepeatKey> {
  static const _initialDelay = Duration(milliseconds: 400);
  static const _interval = Duration(milliseconds: 80);
  Timer? _delay;
  Timer? _timer;
  bool _down = false;

  void _fire() => widget.onPress();

  void _start() {
    if (!widget.enabled) return;
    setState(() => _down = true);
    unawaited(HapticFeedback.lightImpact());
    _fire();
    if (widget.repeat) {
      _delay = Timer(_initialDelay, () {
        _timer = Timer.periodic(_interval, (_) => _fire());
      });
    }
  }

  void _stop() {
    _delay?.cancel();
    _timer?.cancel();
    _delay = null;
    _timer = null;
    if (_down && mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.enabled ? AppColors.text : AppColors.muted;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _start(),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.45,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          padding: EdgeInsets.symmetric(
            horizontal: widget.icon != null ? 5 : 10,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _down ? AppColors.line : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: widget.icon != null
              ? Icon(widget.icon, size: 26, color: fg)
              : Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Bottom sheet content with every VM control. Watches the runtime so the
/// enable rules follow the VM state while the sheet is open.
class _ControlsSheet extends ConsumerWidget {
  const _ControlsSheet({
    required this.vmId,
    required this.busy,
    required this.mirroring,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onShutdown,
    required this.onRestart,
    required this.onForceStop,
    required this.onKeyboard,
    required this.onSpecialKeys,
    required this.onScreenshot,
    required this.onMirror,
  });

  final String vmId;
  final bool busy;
  final bool mirroring;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onShutdown;
  final VoidCallback onRestart;
  final VoidCallback onForceStop;
  final VoidCallback onKeyboard;
  final VoidCallback onSpecialKeys;
  final VoidCallback onScreenshot;
  final VoidCallback onMirror;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vmRuntimeProvider(vmId)).state;
    final off = state == VmState.poweredOff || state == VmState.error;
    final running = state == VmState.running;
    final paused = state == VmState.paused;
    final active = running || paused;
    final canForce = active || state == VmState.stopping;
    VoidCallback? gate(bool ok, VoidCallback f) => ok && !busy ? f : null;
    VoidCallback? live(VoidCallback f) => active ? f : null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const GradientText(
              'Controls',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (off)
                  PrimaryButton(
                    label: 'Start',
                    icon: Icons.play_arrow_rounded,
                    onPressed: gate(true, onStart),
                  ),
                if (paused)
                  PrimaryButton(
                    label: 'Resume',
                    icon: Icons.play_arrow_rounded,
                    onPressed: gate(true, onResume),
                  ),
                if (running)
                  GhostButton(
                    label: 'Pause',
                    icon: Icons.pause_rounded,
                    onPressed: gate(true, onPause),
                  ),
                GhostButton(
                  label: 'Shut down',
                  icon: Icons.power_settings_new_rounded,
                  onPressed: gate(active, onShutdown),
                ),
                GhostButton(
                  label: 'Restart',
                  icon: Icons.restart_alt_rounded,
                  onPressed: gate(running, onRestart),
                ),
                GhostButton(
                  label: 'Force stop',
                  icon: Icons.stop_circle_outlined,
                  onPressed: gate(canForce, onForceStop),
                ),
                GhostButton(
                  label: 'Keyboard',
                  icon: Icons.keyboard_rounded,
                  onPressed: live(onKeyboard),
                ),
                GhostButton(
                  label: 'Keys',
                  icon: Icons.keyboard_command_key_rounded,
                  onPressed: live(onSpecialKeys),
                ),
                GhostButton(
                  label: 'Screenshot',
                  icon: Icons.photo_camera_outlined,
                  onPressed: live(onScreenshot),
                ),
                GhostButton(
                  label: mirroring ? 'Stop mirror' : 'External display',
                  icon: Icons.cast_rounded,
                  onPressed: live(onMirror),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
