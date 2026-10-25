// Vantaris: aviso de «técnico conectado» y modo «no tocar» en el equipo controlado.
//
// Aviso: en Android, mientras haya un técnico conectado se ve arriba una franja con su nombre,
// el tiempo que lleva y un botón para colgar (VantarisGuard.kt). En Windows ya lo hace la
// ventana de conexión de RustDesk.
//
// No tocar: el técnico lo activa desde su barra. Viaja por el mismo canal que la pizarra
// (ver draw.dart):
//   B 1 | B 0      técnico -> equipo: bloquear / desbloquear. Con el modo activo el técnico
//                  repite «B 1» cada pocos segundos; si deja de llegar, el equipo se desbloquea
//                  solo (así una conexión caída nunca deja la pantalla bloqueada).
//   b 0            equipo -> técnico: el usuario ha pulsado «Necesito usar el equipo».
//   V …            videollamada (ver call.dart).
//   R 1 | R 0      técnico -> equipo: se graba la asistencia para el resumen (el aviso lo dice;
//                  el técnico lo repite cada 6 s y sin noticias en 20 s se quita).

// Android: capa que se traga los toques del usuario pero deja pasar los del técnico
// (VantarisGuard.kt + InputService.kt). Windows: el bloqueo real es el de RustDesk
// («Bloquear entrada del usuario»); la capa del runner solo muestra el aviso.

import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';

import '../common.dart';
import '../common/shared_state.dart';
import '../consts.dart';
import '../models/chat_model.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'draw.dart';

/// Cada cuánto repite el técnico «B 1». El equipo se desbloquea solo a los 20 s sin noticias.
const _kHeartbeat = Duration(seconds: 6);

// ---------------------------------------------------------------- lado controlado (Android)

String _lastSession = '';

/// Escucha los cambios de conexiones del servidor Android y muestra/quita el aviso.
void vantarisGuardSync() {
  if (!isAndroid) return;
  final clients = gFFI.serverModel.clients
      .where((c) =>
          c.authorized &&
          !c.disconnected &&
          !c.isFileTransfer &&
          !c.isViewCamera &&
          !c.isTerminal &&
          c.portForward.isEmpty)
      .toList();
  final names = clients.map((c) => c.name.isNotEmpty ? c.name : c.peerId).toSet().join(', ');
  final key = clients.isEmpty ? '' : names;
  if (key == _lastSession) return;
  _lastSession = key;
  gFFI.invokeMethod(
      'vantaris_guard', jsonEncode({'session': clients.isNotEmpty, 'name': names}));
}

/// Órdenes «B» que llegan del técnico (Android).
void vantarisGuardBlock(bool on) {
  if (isAndroid) {
    gFFI.invokeMethod('vantaris_guard', jsonEncode({'block': on}));
  }
}

/// Órdenes «R» del técnico: se está grabando la asistencia para el resumen (Android).
void vantarisGuardRecording(bool on) {
  if (isAndroid) {
    gFFI.invokeMethod('vantaris_guard', jsonEncode({'recording': on}));
  }
}

/// Mensaje de chat normal del técnico (Android controlado). El chat de RustDesk solo se ve
/// dentro de su app; la tarjeta de VantarisGuard.kt sale encima de todo (también de la
/// pizarra y del «no tocar»).
MessageKey? _lastMessageKey;

void vantarisGuardChatMessage(MessageKey key, String text, String? name) {
  if (!isAndroid) return;
  _lastMessageKey = key;
  gFFI.invokeMethod(
      'vantaris_guard', jsonEncode({'message': text, 'name': name ?? ''}));
}

/// Llamadas desde VantarisGuard.kt: el usuario cuelga, pide usar el equipo o quiere responder.
void vantarisGuardOnNative(String method, dynamic arguments) {
  switch (method) {
    case 'vantaris_reply':
      // App al frente con la ventana de chat abierta en la conversación del técnico.
      gFFI.invokeMethod('vantaris_front');
      final chat = gFFI.chatModel;
      final key = _lastMessageKey;
      if (key != null) chat.changeCurrentKey(key);
      if (chat.chatIconOverlayEntry == null) chat.showChatIconOverlay();
      if (chat.chatWindowOverlayEntry == null) chat.showChatWindowOverlay();
      break;
    case 'vantaris_hangup':
      gFFI.serverModel.closeAll();
      break;
    case 'vantaris_unblock':
      for (final c in gFFI.serverModel.clients) {
        if (c.authorized && !c.disconnected) {
          bind.cmSendChat(connId: c.id, msg: '${kVantarisDrawPrefix}b 0');
        }
      }
      break;
  }
}

// ---------------------------------------------------------------- lado técnico

class VantarisGuardState {
  static final _states = <SessionID, VantarisGuardState>{};

  static VantarisGuardState of(FFI ffi) =>
      _states.putIfAbsent(ffi.sessionId, () => VantarisGuardState._(ffi));

  static VantarisGuardState? find(SessionID sessionId) => _states[sessionId];

  static void disposeFor(SessionID sessionId) => _states.remove(sessionId)?._stop();

  VantarisGuardState._(this.ffi);

  final FFI ffi;
  final RxBool blocking = false.obs;
  final RxBool checking = false.obs;
  Timer? _heartbeat;

  SessionID get _sid => ffi.sessionId;

  bool get _peerIsWindows =>
      ffi.ffiModel.pi.platform == kPeerPlatformWindows;

  void _send(String body) {
    vantarisDebugTee?.call(body);
    bind.sessionSendChat(sessionId: _sid, text: kVantarisDrawPrefix + body);
  }

  Future<void> toggle() async {
    if (blocking.value) {
      _setOff(notifyPeer: true);
      return;
    }
    if (checking.value) return;
    checking.value = true;
    final ok = await vantarisPeerSupportsDraw(_sid);
    checking.value = false;
    if (!ok) {
      showToast('Este equipo no tiene el cliente Vantaris: no se puede bloquear.',
          timeout: const Duration(seconds: 5));
      return;
    }
    blocking.value = true;
    _send('B 1');
    _heartbeat = Timer.periodic(_kHeartbeat, (_) => _send('B 1'));
    // En Windows el bloqueo de verdad lo hace RustDesk.
    if (_peerIsWindows) _setBuiltinBlock(true);
  }

  /// El usuario del equipo ha pedido usarlo.
  void onPeerUnblocked() {
    if (!blocking.value) return;
    _setOff(notifyPeer: false);
    showToast('El cliente ha pedido usar el equipo: ya no está bloqueado.',
        timeout: const Duration(seconds: 6));
  }

  void _setOff({required bool notifyPeer}) {
    _heartbeat?.cancel();
    _heartbeat = null;
    blocking.value = false;
    if (notifyPeer) _send('B 0');
    if (_peerIsWindows) _setBuiltinBlock(false);
  }

  void _setBuiltinBlock(bool on) {
    final id = ffi.id;
    final state = BlockInputState.find(id);
    if (state.value == on) return;
    bind.sessionToggleOption(
        sessionId: _sid, value: '${on ? '' : 'un'}block-input');
    state.value = on;
  }

  void _stop() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}

/// Mensaje del equipo controlado para el técnico ([body] sin prefijo).
void vantarisGuardFromPeer(SessionID sessionId, String body) {
  if (body.trim() == 'b 0') VantarisGuardState.find(sessionId)?.onPeerUnblocked();
}
