import 'package:flutter_test/flutter_test.dart';
import 'package:vm_machine/domain/domain.dart';

MediaRef iso(String path, {String? name}) =>
    MediaRef(path: path, kind: MediaKind.iso, displayName: name);

void main() {
  group('detectFromName', () {
    test('recognizes x86_64 indicators regardless of case and separators', () {
      for (final n in [
        'debian-live-13.8.0-amd64-gnome.iso',
        'Ubuntu_AMD64.ISO',
        'win11.x86_64.iso',
        'os-x86-64.iso',
        'os x64 edition.iso',
      ]) {
        expect(
          ArchMismatchDetector.detectFromName(n),
          GuestArch.x86_64,
          reason: n,
        );
      }
    });

    test('recognizes ARM64 indicators', () {
      for (final n in [
        'alpine-aarch64.iso',
        'Fedora-ARM64.iso',
        'a_arm64_b.iso',
      ]) {
        expect(
          ArchMismatchDetector.detectFromName(n),
          GuestArch.arm64,
          reason: n,
        );
      }
    });

    test('returns null for ambiguous names', () {
      for (final n in [
        'ubuntu-24.04.iso',
        'amd64-and-arm64.iso',
        'notamd64x.iso',
        'disk64.iso',
      ]) {
        expect(ArchMismatchDetector.detectFromName(n), isNull, reason: n);
      }
    });
  });

  group('hint', () {
    final amd = iso(
      'content://media/42',
      name: 'debian-live-13.8.0-amd64-standard.iso',
    );

    test('warns for amd64 media on an ARM64 VM using the display name', () {
      final h = ArchMismatchDetector.hint([amd], GuestArch.arm64);
      expect(h, contains('x86_64'));
      expect(h, contains('ARM64'));
    });

    test('warns for arm64 media on an x86_64 VM', () {
      final h = ArchMismatchDetector.hint([
        iso('/m/alpine-aarch64.iso'),
      ], GuestArch.x86_64);
      expect(h, contains('ARM64 image'));
    });

    test('no hint when matching, ambiguous or no media', () {
      expect(ArchMismatchDetector.hint([amd], GuestArch.x86_64), isNull);
      expect(
        ArchMismatchDetector.hint([iso('/m/a.iso')], GuestArch.arm64),
        isNull,
      );
      expect(ArchMismatchDetector.hint(const [], GuestArch.arm64), isNull);
    });
  });

  group('FailureMessage', () {
    const f = StartFailure('Launch', 'boom');

    test('appends the arch hint', () {
      final m = FailureMessage.format(f, crossArch: true, archHint: 'HINT');
      expect(m, endsWith('\nHINT'));
      expect(m, contains(FailureMessage.slowBootHint));
    });

    test('is unchanged without a hint', () {
      expect(
        FailureMessage.format(f, crossArch: false),
        'Failed at step "Launch": boom',
      );
    });
  });
}
