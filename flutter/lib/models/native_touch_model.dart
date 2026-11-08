import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../common.dart';
import '../utils/native_touch.dart';
import 'model.dart';
import 'input_model.dart';
import 'platform_model.dart';

class NativeTouchModel extends ChangeNotifier {
  NativeTouchModel(this.parent);
  final WeakReference<FFI> parent;
  final contacts = NativeTouchContacts();
  bool optIn = false;
  bool requested = false;
  bool ready = false;
  int? display;
  Timer? _heartbeat;
  Timer? _initialization;
  Future<void> _sending = Future.value();
  int _generation = 0;

  bool get supported {
    final ffi = parent.target;
    final maximum =
        ffi?.ffiModel.pi.platformAdditions['native_touch_max_contacts'];
    return !isWeb && isIOS && ffi != null && maximum is num && maximum >= 10;
  }

  void setOptIn(bool value) {
    optIn = value;
    final model = parent.target?.ffiModel;
    if (value && model != null && !model.touchMode) model.toggleTouchMode();
    if (value) parent.target?.inputModel.setRelativeMouseMode(false);
    setEnabled(value);
    _notify();
  }

  void setEnabled(bool enabled) {
    final ffi = parent.target;
    final model = ffi?.ffiModel;
    enabled = enabled &&
        supported &&
        model != null &&
        model.keyboard &&
        !model.viewOnly &&
        model.pi.currentDisplay >= 0;
    if (enabled == requested) return;
    _generation++;
    if (enabled && ffi != null) {
      ffi.inputModel.sendMouse('up', MouseButtons.left);
      display = ffi.ffiModel.pi.currentDisplay;
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    _initialization?.cancel();
    _initialization = null;
    contacts.clear();
    ready = false;
    requested = enabled;
    _send(enabled: enabled, start: enabled);
    if (enabled) {
      _initialization =
          Timer(const Duration(seconds: 6), () => fail('Connection timeout'));
    }
    _notify();
  }

  void handleStatus(Map<String, dynamic> event) {
    if (int.tryParse('${event['display']}') != display) return;
    if (!requested) {
      if (event['enabled'] == 'true') _send(enabled: false);
      return;
    }
    _initialization?.cancel();
    _initialization = null;
    if (event['enabled'] != 'true') {
      fail(event['error'] as String? ?? '');
      return;
    }
    ready = true;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
        const Duration(milliseconds: 100), (_) => sendContacts());
    _notify();
  }

  void sendContacts() {
    if (requested && ready) _send(enabled: true);
  }

  void cancelContacts() {
    contacts.clear();
    sendContacts();
  }

  void onDisplayChanged(int nextDisplay) {
    if (!requested) return;
    if (display == nextDisplay) {
      cancelContacts();
      return;
    }
    if (nextDisplay >= 0) {
      setEnabled(false);
      setEnabled(true);
      return;
    }
    setOptIn(false);
    final model = parent.target?.ffiModel;
    if (model != null && model.touchMode) model.toggleTouchMode();
  }

  void onConnectionChanged() {
    final wasNative = requested || optIn;
    reset();
    if (wasNative) {
      final model = parent.target?.ffiModel;
      if (model != null && model.touchMode) model.toggleTouchMode();
      _notify();
    }
  }

  void fail(String reason) {
    optIn = false;
    setEnabled(false);
    final ffi = parent.target;
    if (ffi != null && ffi.ffiModel.touchMode) ffi.ffiModel.toggleTouchMode();
    showToast(
        '${translate('Native touch (experimental)')}: ${reason.isEmpty ? translate('Mouse mode') : reason}');
    _notify();
  }

  void reset() {
    _generation++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _initialization?.cancel();
    _initialization = null;
    optIn = requested = ready = false;
    display = null;
    contacts.clear();
  }

  void _notify() => notifyListeners();

  void _send({required bool enabled, bool start = false}) {
    final ffi = parent.target;
    final currentDisplay = display;
    if (ffi == null || currentDisplay == null) return;
    final message = jsonEncode({
      'k': 'raw_touch',
      'v': {
        'enabled': enabled,
        'display': currentDisplay,
        'start': start,
        'contacts': enabled ? contacts.snapshot : [],
      }
    });
    final generation = _generation;
    // Preserve down/up transitions across asynchronous bridge calls.
    _sending = _sending.then((_) async {
      if (generation != _generation) return;
      await bind.sessionSendPointer(sessionId: ffi.sessionId, msg: message);
    }).catchError((Object error) {
      debugPrint('Native touch bridge failed: $error');
      reset();
      final model = parent.target?.ffiModel;
      if (model != null && model.touchMode) model.toggleTouchMode();
      showToast('${translate('Native touch (experimental)')}: $error');
      _notify();
    });
  }
}
