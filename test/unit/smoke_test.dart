import 'package:glados/glados.dart';

void main() {
  Glados(any.int).test('glados runs', (n) {
    expect(n + 0, n);
  });
}
