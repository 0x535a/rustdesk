import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../utils/native_touch.dart';

class NativeTouchRegion extends StatefulWidget {
  const NativeTouchRegion({super.key, required this.ffi, required this.child});
  final FFI ffi;
  final Widget child;
  @override
  State<NativeTouchRegion> createState() => _NativeTouchRegionState();
}

class _NativeTouchRegionState extends State<NativeTouchRegion>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => widget.ffi.ffiModel.nativeTouch.cancelContacts();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      final model = widget.ffi.ffiModel;
      model.nativeTouch.setOptIn(false);
      if (model.touchMode) model.toggleTouchMode();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.ffi.ffiModel.nativeTouch.cancelContacts();
    super.dispose();
  }

  Offset? _point(Offset local, {bool clamp = false}) {
    final ffi = widget.ffi;
    final rect = ffi.ffiModel.rect;
    if (rect == null ||
        (!clamp && ffi.cursorModel.shouldBlock(local.dx, local.dy))) {
      return null;
    }
    final canvas = ffi.canvasModel;
    final image = Rect.fromLTWH(canvas.x, canvas.y + canvas.getAdjustY(),
        rect.width * canvas.scale, rect.height * canvas.scale);
    return normalizeNativeTouch(local, image, clamp: clamp);
  }

  @override
  Widget build(BuildContext context) {
    final touch = widget.ffi.ffiModel.nativeTouch;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.touch || !touch.ready) return;
        final point = _point(event.localPosition);
        if (point != null && touch.contacts.begin(event.pointer, point)) {
          touch.sendContacts();
        }
      },
      onPointerMove: (event) {
        if (event.kind != PointerDeviceKind.touch || !touch.ready) return;
        final point = _point(event.localPosition, clamp: true);
        if (point != null && touch.contacts.move(event.pointer, point)) {
          touch.sendContacts();
        }
      },
      onPointerUp: (event) {
        if (event.kind == PointerDeviceKind.touch &&
            touch.contacts.end(event.pointer)) {
          touch.sendContacts();
        }
      },
      onPointerCancel: (event) {
        if (event.kind == PointerDeviceKind.touch &&
            touch.contacts.end(event.pointer)) {
          touch.sendContacts();
        }
      },
      child: widget.child,
    );
  }
}

class NativeTouchControls extends StatelessWidget {
  const NativeTouchControls({super.key, required this.ffi});
  final FFI ffi;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: ffi.ffiModel,
        builder: (context, _) {
          final touch = ffi.ffiModel.nativeTouch;
          if (!touch.supported) return const SizedBox.shrink();
          void adjust(VoidCallback operation) {
            touch.cancelContacts();
            operation();
          }

          Widget button(IconData icon, String hint, VoidCallback operation) =>
              IconButton(
                  icon: Icon(icon),
                  tooltip: translate(hint),
                  onPressed: () => adjust(operation));
          return Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
              title: Text(translate('Native touch (experimental)')),
              value: touch.optIn,
              onChanged: (value) => touch.setOptIn(value ?? false),
            ),
            if (touch.requested && !touch.ready)
              const LinearProgressIndicator(),
            if (touch.ready)
              Wrap(alignment: WrapAlignment.center, children: [
                button(Icons.zoom_out, 'Zoom out',
                    () => ffi.canvasModel.updateScale(0.8, Offset.zero)),
                button(Icons.zoom_in, 'Zoom in',
                    () => ffi.canvasModel.updateScale(1.25, Offset.zero)),
                button(
                    Icons.fit_screen,
                    'Reset canvas',
                    () => ffi.canvasModel
                        .updateViewStyle(refreshMousePos: false)),
                button(Icons.arrow_back, 'Move image left',
                    () => ffi.canvasModel.panX(-80)),
                button(Icons.arrow_forward, 'Move image right',
                    () => ffi.canvasModel.panX(80)),
                button(Icons.arrow_upward, 'Move image up',
                    () => ffi.canvasModel.panY(-80)),
                button(Icons.arrow_downward, 'Move image down',
                    () => ffi.canvasModel.panY(80)),
              ]),
          ]);
        },
      );
}
