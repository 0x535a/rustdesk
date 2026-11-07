import 'dart:ui';

Offset? normalizeNativeTouch(Offset local, Rect image, {bool clamp = false}) {
  if (image.isEmpty || !local.dx.isFinite || !local.dy.isFinite) return null;
  final x = (local.dx - image.left) / image.width;
  final y = (local.dy - image.top) / image.height;
  if (!clamp && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
  return Offset(x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble());
}

class NativeTouchContacts {
  static const maximum = 10;
  final Map<int, Map<String, Object>> _contacts = {};
  int _nextId = 1;

  List<Map<String, Object>> get snapshot =>
      _contacts.values.map((point) => Map<String, Object>.of(point)).toList();

  bool begin(int pointer, Offset point) {
    if (_contacts.containsKey(pointer) || _contacts.length >= maximum) {
      return false;
    }
    while (_contacts.values.any((p) => p['id'] == _nextId)) {
      _nextId = _nextId == 127 ? 1 : _nextId + 1;
    }
    _contacts[pointer] = {'id': _nextId, 'x': point.dx, 'y': point.dy};
    _nextId = _nextId == 127 ? 1 : _nextId + 1;
    return true;
  }

  bool move(int pointer, Offset point) {
    final contact = _contacts[pointer];
    if (contact == null) return false;
    contact['x'] = point.dx;
    contact['y'] = point.dy;
    return true;
  }

  bool end(int pointer) => _contacts.remove(pointer) != null;
  void clear() => _contacts.clear();
}
