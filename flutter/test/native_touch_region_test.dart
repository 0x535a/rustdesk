import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/common/widgets/native_touch.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/native_touch_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/native_touch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  final frames = <Map<String, dynamic>>[];
  @override
  Future<void> sessionSendPointer(
      {required UuidValue sessionId, required String msg, dynamic hint}) async {
    frames.add(jsonDecode(msg)['v'] as Map<String, dynamic>);
  }
}

class _SupportedTouch extends NativeTouchModel {
  _SupportedTouch(FFI ffi) : super(WeakReference(ffi));
  @override
  bool get supported => true;
}

class _Input extends Fake implements InputModel {
  @override
  Future<void> sendMouse(String type, MouseButtons button) async {}
}

class _Touch extends Fake implements NativeTouchModel {
  @override
  final contacts = NativeTouchContacts();
  @override
  bool get ready => true;
  final frames = <List<Map<String, Object>>>[];
  @override
  void sendContacts() => frames.add(contacts.snapshot);
  @override
  void cancelContacts() {
    contacts.clear();
    sendContacts();
  }
}

class _Model extends Fake implements FfiModel {
  _Model(this.nativeTouch);
  @override
  final NativeTouchModel nativeTouch;
  @override
  final pi = PeerInfo();
  @override
  bool get keyboard => true;
  @override
  bool get viewOnly => false;
  @override
  bool get touchMode => false;
  @override
  Rect get rect => const Rect.fromLTWH(0, 0, 400, 300);
}

class _Canvas extends Fake implements CanvasModel {
  @override
  double get x => 100;
  @override
  double get y => 50;
  @override
  double get scale => 1;
  @override
  double getAdjustY() => 0;
}

class _Cursor extends Fake implements CursorModel {
  @override
  bool shouldBlock(double x, double y) => false;
}

class _Session extends Fake implements FFI {
  _Session(this.ffiModel);
  @override
  final FfiModel ffiModel;
  @override
  final sessionId = const Uuid().v4obj();
  @override
  final inputModel = _Input();
  @override
  final canvasModel = _Canvas();
  @override
  final cursorModel = _Cursor();
}

void main() {
  testWidgets('switching monitors keeps native touch and rebinds new contacts',
      (tester) async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    final model = _Model(_Touch());
    final session = _Session(model);
    final touch = _SupportedTouch(session);
    addTearDown(touch.reset);
    touch.optIn = true;
    touch.setEnabled(true);
    await tester.pump();
    touch.handleStatus({'display': '0', 'enabled': 'true'});
    touch.contacts.begin(1, const Offset(0.25, 0.5));
    model.pi.currentDisplay = 1;
    touch.onDisplayChanged(1);
    await tester.pump();
    expect(touch.optIn && touch.requested, isTrue);
    expect(touch.ready, isFalse);
    expect(binding.frames.last, {
      'enabled': true, 'display': 1, 'start': true, 'contacts': [],
    });
    touch.handleStatus({'display': '1', 'enabled': 'true'});
    touch.contacts.begin(2, const Offset(0.75, 0.5));
    touch.sendContacts();
    await tester.pump();
    expect(touch.ready, isTrue);
    expect(binding.frames.last['display'], 1);
    final contacts = binding.frames.last['contacts'] as List;
    expect(contacts, hasLength(1));
    expect(contacts.single['x'], 0.75);
    expect(contacts.single['y'], 0.5);
    touch.onDisplayChanged(1);
    await tester.pump();
    expect(binding.frames.last['contacts'], isEmpty);
    expect(touch.ready, isTrue);
    touch.reset();
  });

  testWidgets('native region forwards ten raw contacts and ignores mouse input',
      (tester) async {
    final touch = _Touch();
    final session = _Session(_Model(touch));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NativeTouchRegion(
      ffi: session,
      child: const SizedBox.expand(),
    ))));
    final fingers = <TestGesture>[];
    for (var i = 0; i < 10; i++) {
      fingers.add(await tester.startGesture(Offset(150 + i * 20, 150),
          pointer: i + 1, kind: PointerDeviceKind.touch));
    }
    expect(touch.frames.last.length, 10);
    final firstId = touch.frames.last.first['id'];
    final beforeMouse = touch.frames.length;
    final mouse = await tester.startGesture(const Offset(250, 200),
        pointer: 100, kind: PointerDeviceKind.mouse);
    await mouse.up();
    expect(touch.frames.length, beforeMouse);
    await fingers.first.moveTo(const Offset(350, 200));
    expect(touch.frames.last.first, {'id': firstId, 'x': 0.625, 'y': 0.5});
    await fingers.last.cancel();
    expect(touch.frames.last.length, 9);
    for (final finger in fingers.take(9)) {
      await finger.up();
    }
    expect(touch.frames.last, isEmpty);
  });
}
