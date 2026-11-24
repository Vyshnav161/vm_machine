import 'package:flutter_test/flutter_test.dart';
import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/ui/screens/vm_form_screen.dart';

void main() {
  const inPlace = MediaRef(path: 'content://d/msf:1', kind: MediaKind.iso);
  const copied = MediaRef(
    path: '/m/a.iso',
    kind: MediaKind.iso,
    copiedIntoAppStorage: true,
  );

  test('label prefers the display name over the uri', () {
    expect(inPlace.copyWith(displayName: 'a.iso').label, 'a.iso');
    expect(
      const MediaRef(path: '/m/b%20c.iso', kind: MediaKind.iso).label,
      'b c.iso',
    );
  });

  test('storage label follows the copy toggle', () {
    expect(mediaStorageLabel(inPlace, copyToggle: false), 'in place');
    expect(mediaStorageLabel(inPlace, copyToggle: true), isNot('in place'));
    expect(mediaStorageLabel(copied, copyToggle: true), 'copied');
    expect(mediaStorageLabel(copied, copyToggle: false), 'copied');
  });
}
