import 'package:flutter_test/flutter_test.dart';
import 'package:metrickle/metrickle.dart';

void main() {
  test('A → B → A within 7s is a u-turn', () {
    final detect = uTurnDetector();
    expect(detect('A', 0), isNull);
    expect(detect('B', 1000), isNull);
    final t = detect('A', 3000)!;
    expect((t.from, t.to, t.dwellMs), ('B', 'A', 2000));
  });

  test('slow returns, repeats and new screens are not u-turns', () {
    final detect = uTurnDetector();
    detect('A', 0);
    detect('B', 1000);
    expect(detect('A', 8000), isNull); // stayed 7s on B
    expect(detect('A', 8100), isNull); // same screen again
    expect(detect('C', 9000), isNull);
    expect(detect('D', 9500), isNull);
    expect(detect('C', 10000), isNotNull);
  });
}
