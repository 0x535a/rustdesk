import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/native_touch.dart';

void main() {
  test('ten contacts keep IDs through movement and release', () {
    final contacts = NativeTouchContacts();
    for (var pointer = 1; pointer <= 10; pointer++) {
      expect(contacts.begin(pointer, Offset(pointer / 10, 0.5)), isTrue);
    }
    expect(contacts.begin(11, Offset.zero), isFalse);
    final ids = contacts.snapshot.map((p) => p['id']).toList();
    for (var pointer = 1; pointer <= 10; pointer++) {
      contacts.move(pointer, const Offset(0.4, 0.6));
    }
    expect(contacts.snapshot.map((p) => p['id']).toList(), ids);
    expect(
        contacts.snapshot.every((p) => p['x'] == 0.4 && p['y'] == 0.6), isTrue);
    for (var pointer = 1; pointer <= 5; pointer++) {
      contacts.end(pointer);
    }
    expect(contacts.snapshot.length, 5);
    contacts.clear();
    expect(contacts.snapshot, isEmpty);
    expect(contacts.move(6, Offset.zero), isFalse);
  });

  test('coordinates respect letterboxing, zoom and clamped moves', () {
    const image = Rect.fromLTWH(40, 100, 800, 400);
    expect(normalizeNativeTouch(const Offset(440, 300), image),
        const Offset(0.5, 0.5));
    expect(normalizeNativeTouch(const Offset(10, 300), image), isNull);
    expect(normalizeNativeTouch(const Offset(900, 50), image, clamp: true),
        const Offset(1, 0));
    expect(normalizeNativeTouch(Offset.zero, Rect.zero), isNull);
  });
}
