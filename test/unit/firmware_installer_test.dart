import 'package:flutter_test/flutter_test.dart';
import 'package:vm_machine/services/firmware_service.dart';

class _FakeSource implements FirmwareSource {
  _FakeSource(this.version);
  String? version;
  final extracted = <String>[];

  @override
  Future<String?> bundledVersion() async => version;

  @override
  Future<void> extractTo(String dest) async => extracted.add(dest);
}

void main() {
  test('copies when nothing is installed, then not again', () async {
    final src = _FakeSource('qemu=9 edk2=1');
    String? installed;
    final inst = FirmwareInstaller(
      source: src,
      readInstalledVersion: (_) async => installed,
    );
    expect(await inst.ensureInstalled('/docs/qemu'), true);
    installed = 'qemu=9 edk2=1\n'; // marker copied with the files
    expect(await inst.ensureInstalled('/docs/qemu'), false);
    expect(src.extracted, ['/docs/qemu']);
  });

  test('a new bundled version recopies', () async {
    final src = _FakeSource('qemu=9 edk2=2');
    final inst = FirmwareInstaller(
      source: src,
      readInstalledVersion: (_) async => 'qemu=9 edk2=1',
    );
    expect(await inst.ensureInstalled('/d'), true);
    expect(src.extracted.length, 1);
  });

  test('nothing is copied when no firmware is bundled', () async {
    final src = _FakeSource(null);
    final inst = FirmwareInstaller(
      source: src,
      readInstalledVersion: (_) async => null,
    );
    expect(await inst.ensureInstalled('/d'), false);
    expect(src.extracted, isEmpty);
  });
}
