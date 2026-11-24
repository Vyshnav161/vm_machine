import 'package:glados/glados.dart';
import 'package:vm_machine/domain/domain.dart';

const _gib = 1024 * 1024 * 1024;

void main() {
  group('CompatibilityEvaluator', () {
    test('all Unknown host yields six runnable entries, software mode', () {
      final r = CompatibilityEvaluator.evaluate(const HostCapabilities());
      expect(r.entries.length, 6);
      expect(r.entries.every((e) => e.runnable), true);
      expect(
        r.entries.every((e) => e.mode == AccelerationMode.softwareEmulation),
        true,
      );
      expect(r.host, const HostCapabilities());
    });

    test('arm64 guest on arm64 host with Known(true) uses hardware virt', () {
      final r = CompatibilityEvaluator.evaluate(
        const HostCapabilities(
          arch: Known(GuestArch.arm64),
          hardwareVirtualization: Known(true),
        ),
      );
      expect(
        r.entryFor(GuestOs.linux, GuestArch.arm64)!.mode,
        AccelerationMode.hardwareVirtualization,
      );
      final x86 = r.entryFor(GuestOs.linux, GuestArch.x86_64)!;
      expect(x86.mode, AccelerationMode.softwareEmulation);
      expect(x86.warnings, [CompatibilityWarning.reducedPerformance]);
    });

    test('Known(false) virtualization falls back to software', () {
      final r = CompatibilityEvaluator.evaluate(
        const HostCapabilities(
          arch: Known(GuestArch.arm64),
          hardwareVirtualization: Known(false),
        ),
      );
      expect(
        r.entryFor(GuestOs.linux, GuestArch.arm64)!.mode,
        AccelerationMode.softwareEmulation,
      );
    });

    test('low RAM warning boundary at 4 GiB', () {
      CompatibilityReport at(int bytes) => CompatibilityEvaluator.evaluate(
        HostCapabilities(totalRamBytes: Known(bytes)),
      );
      bool warned(CompatibilityReport r, GuestOs os) => r
          .entryFor(os, GuestArch.arm64)!
          .warnings
          .contains(CompatibilityWarning.notRecommendedLowRam);
      expect(warned(at(4 * _gib - 1), GuestOs.windows), true);
      expect(warned(at(4 * _gib - 1), GuestOs.macos), true);
      expect(warned(at(4 * _gib - 1), GuestOs.linux), false);
      expect(warned(at(4 * _gib), GuestOs.windows), false);
    });
  });

  group('RecommendedDefaults', () {
    test('per-OS values', () {
      expect(
        RecommendedDefaults.forOs(GuestOs.linux),
        const DefaultResources(2, 2048, 16 * _gib),
      );
      expect(
        RecommendedDefaults.forOs(GuestOs.windows),
        const DefaultResources(4, 4096, 64 * _gib),
      );
      expect(
        RecommendedDefaults.forOs(GuestOs.macos),
        const DefaultResources(4, 4096, 64 * _gib),
      );
    });
  });
}
