// Vantaris: videollamada técnico ↔ cliente con WebRTC (flutter_webrtc).
//
// La señalización (oferta, respuesta y candidatos ICE) viaja por el canal de la pizarra (ver
// draw.dart), así que no hace falta otro servidor para montarla: basta la conexión de RustDesk
// ya abierta. El vídeo y el audio van directos entre los dos equipos (STUN); si las redes no lo
// permiten hace falta un TURN: el de soporte.vantaris.es (coturn, RemoteControl/deploy/pro) va
// dentro del Técnico al compilar (--dart-define=VANTARIS_TURN, lo pone build-vantaris.sh desde
// secrets/turn-vantaris.json); la opción local «vantaris-turn» o la variable VANTARIS_TURN lo
// sustituyen. JSON con urls/username/credential; el técnico lo manda en la oferta.
//
// Órdenes: «V <llamada> <i>/<n> <trozo>»: un JSON en base64url partido en trozos (una SDP ocupa
// varios KB). Tipos: offer, answer, ice, bye, decline.
//
// Técnico: botón de la barra y panel flotante en la vista remota (VantarisCallPanel).
// Equipo controlado: el usuario tiene que aceptar; la llamada se ve en una página propia
// (Android: la app pasa al frente; Windows: en la ventana de conexión).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart' hide navigator;

import '../common.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'draw.dart';
import 'play.dart';

const _kChunk = 3000;
const _kTurnCompilado = String.fromEnvironment('VANTARIS_TURN');
const _kRingTimeout = Duration(seconds: 45);

List<Map<String, dynamic>> _defaultIce() {
  final servers = <Map<String, dynamic>>[
    {'urls': 'stun:soporte.vantaris.es:3478'},
    // Vantaris Play: solo nuestro STUN/TURN (sin terceros).
    if (!kVantarisPlay) {'urls': 'stun:stun.l.google.com:19302'},
  ];
  String turn = '';
  try {
    turn = Platform.environment['VANTARIS_TURN'] ?? '';
  } catch (_) {}
  if (turn.isEmpty) turn = bind.mainGetLocalOption(key: 'vantaris-turn');
  if (turn.isEmpty) turn = _kTurnCompilado;
  if (turn.isNotEmpty) {
    try {
      servers.add(Map<String, dynamic>.from(jsonDecode(turn) as Map));
    } catch (_) {}
  }
  return servers;
}

// ---------------------------------------------------------------- troceado de mensajes

List<String> _encode(String callId, Map<String, dynamic> msg) {
  final b = base64Url.encode(utf8.encode(jsonEncode(msg))).replaceAll('=', '');
  final n = max(1, (b.length / _kChunk).ceil());
  return [
    for (var i = 0; i < n; i++)
      'V $callId ${i + 1}/$n ${b.substring(i * _kChunk, min(b.length, (i + 1) * _kChunk))}'
  ];
}

final _parts = <String, List<String?>>{};

/// Junta los trozos; devuelve (llamada, mensaje) cuando está completo.
(String, Map<String, dynamic>)? _decodeLine(String line) {
  final p = line.trim().split(' ');
  if (p.length < 4 || p[0] != 'V') return null;
  final callId = p[1];
  final idx = p[2].split('/');
  final i = int.tryParse(idx[0]), n = int.tryParse(idx.length > 1 ? idx[1] : '');
  if (i == null || n == null || i < 1 || i > n || n > 200) return null;
  final key = '$callId/$n';
  final list = _parts.putIfAbsent(key, () => List<String?>.filled(n, null));
  // Mensajes distintos de la misma llamada pueden tener igual número de trozos: se vacía al completar.
  list[i - 1] = p[3];
  if (list.any((e) => e == null)) return null;
  _parts.remove(key);
  var b = list.join();
  while (b.length % 4 != 0) {
    b += '=';
  }
  try {
    final m = jsonDecode(utf8.decode(base64Url.decode(b))) as Map<String, dynamic>;
    return (callId, m);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- la llamada

class VantarisCall {
  final String id;
  final bool caller;
  final void Function(String line) _sendLine;
  final void Function(VantarisCall call) onEnded;
  List<Map<String, dynamic>> iceServers;

  VantarisCall(
      {required this.id,
      required this.caller,
      required void Function(String line) sendLine,
      required this.onEnded,
      List<Map<String, dynamic>>? ice})
      : _sendLine = sendLine,
        iceServers = ice ?? _defaultIce();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  final RxString status = ''.obs;
  final RxBool connected = false.obs;
  final RxBool micOn = true.obs;
  final RxBool camOn = true.obs;
  final RxBool hasLocalVideo = false.obs;
  final RxBool hasRemoteVideo = false.obs;
  final _pendingIce = <RTCIceCandidate>[];
  bool _remoteSet = false;
  bool _ended = false;
  bool _renderersReady = false;
  Timer? _ringTimer;

  void _send(Map<String, dynamic> m) {
    for (final l in _encode(id, m)) {
      _sendLine(l);
    }
  }

  Future<void> _init() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<MediaStream?> _media() async {
    final video = {
      'facingMode': 'user',
      'width': {'ideal': 640},
      'height': {'ideal': 480},
    };
    for (final c in [
      {'audio': true, 'video': video},
      {'audio': true, 'video': false},
      {'audio': false, 'video': video},
    ]) {
      try {
        return await navigator.mediaDevices.getUserMedia(c);
      } catch (_) {}
    }
    return null;
  }

  Future<void> _createPc() async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send({'t': 'ice', 'c': c.candidate, 'm': c.sdpMid, 'i': c.sdpMLineIndex});
    };
    pc.onTrack = (e) {
      if (e.streams.isNotEmpty) remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') hasRemoteVideo.value = true;
    };
    pc.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          connected.value = true;
          status.value = '';
          _ringTimer?.cancel();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          status.value = 'Conexión inestable…';
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          hangup(reason: 'No se pudo conectar el vídeo (red). Hace falta un servidor TURN.');
          break;
        default:
          break;
      }
    };
    final local = await _media();
    _local = local;
    if (local != null) {
      localRenderer.srcObject = local;
      hasLocalVideo.value = local.getVideoTracks().isNotEmpty;
      micOn.value = local.getAudioTracks().isNotEmpty;
      camOn.value = hasLocalVideo.value;
      for (final t in local.getTracks()) {
        await pc.addTrack(t, local);
      }
    }
    // Aunque aquí no haya cámara o micrófono, se quiere recibir lo del otro lado.
    if (local == null || local.getVideoTracks().isEmpty) {
      await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
    }
    if (local == null || local.getAudioTracks().isEmpty) {
      await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
    }
  }

  /// Técnico: llama.
  Future<void> start() async {
    status.value = 'Llamando…';
    try {
      await _init();
      await _createPc();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send({'t': 'offer', 'sdp': offer.sdp, 'ice': iceServers});
      _ringTimer = Timer(_kRingTimeout, () {
        if (!connected.value) hangup(reason: 'No contesta.');
      });
    } catch (e) {
      hangup(reason: 'No se pudo empezar la videollamada: $e');
    }
  }

  /// Equipo: acepta una oferta.
  Future<void> accept(Map<String, dynamic> offer) async {
    status.value = 'Conectando…';
    final ice = offer['ice'];
    if (ice is List) {
      iceServers = ice.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    try {
      await _init();
      await _createPc();
      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String, 'offer'));
      _remoteSet = true;
      await _flushIce();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _send({'t': 'answer', 'sdp': answer.sdp});
    } catch (e) {
      hangup(reason: 'No se pudo aceptar la videollamada: $e');
    }
  }

  Future<void> _flushIce() async {
    for (final c in _pendingIce) {
      try {
        await _pc?.addCandidate(c);
      } catch (_) {}
    }
    _pendingIce.clear();
  }

  Future<void> onMessage(Map<String, dynamic> m) async {
    switch (m['t']) {
      case 'answer':
        try {
          await _pc?.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, 'answer'));
          _remoteSet = true;
          status.value = 'Conectando…';
          await _flushIce();
        } catch (e) {
          hangup(reason: 'Respuesta no válida: $e');
        }
        break;
      case 'ice':
        final c = RTCIceCandidate(
            m['c'] as String?, m['m'] as String?, (m['i'] as num?)?.toInt());
        if (_remoteSet && _pc != null) {
          try {
            await _pc!.addCandidate(c);
          } catch (_) {}
        } else {
          _pendingIce.add(c);
        }
        break;
      case 'bye':
        hangup(notify: false, reason: 'Han colgado.');
        break;
      case 'decline':
        hangup(notify: false, reason: m['busy'] == true
            ? 'El equipo ya está en otra videollamada.'
            : 'El cliente no ha aceptado la videollamada.');
        break;
    }
  }

  void toggleMic() {
    final tracks = _local?.getAudioTracks() ?? [];
    if (tracks.isEmpty) return;
    micOn.value = !micOn.value;
    for (final t in tracks) {
      t.enabled = micOn.value;
    }
  }

  void toggleCam() {
    final tracks = _local?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    camOn.value = !camOn.value;
    for (final t in tracks) {
      t.enabled = camOn.value;
    }
  }

  /// Motivo del último final de llamada (para la demo automática).
  static String? lastEndReason;

  Future<void> hangup({bool notify = true, String? reason}) async {
    if (_ended) return;
    _ended = true;
    lastEndReason = reason ?? (notify ? 'colgada aquí' : 'colgada allí');
    _ringTimer?.cancel();
    if (notify) _send({'t': 'bye'});
    if (reason != null) showToast(reason, timeout: const Duration(seconds: 5));
    try {
      for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
      await _pc?.close();
      if (_renderersReady) {
        localRenderer.srcObject = null;
        remoteRenderer.srcObject = null;
        await localRenderer.dispose();
        await remoteRenderer.dispose();
      }
    } catch (_) {}
    onEnded(this);
  }
}

// ---------------------------------------------------------------- lado técnico

class VantarisCallState {
  static final _states = <SessionID, VantarisCallState>{};

  static VantarisCallState of(FFI ffi) =>
      _states.putIfAbsent(ffi.sessionId, () => VantarisCallState._(ffi));

  static void disposeFor(SessionID sid) => _states.remove(sid)?.call.value?.hangup();

  VantarisCallState._(this.ffi);

  final FFI ffi;
  final Rx<VantarisCall?> call = Rx<VantarisCall?>(null);
  final RxBool checking = false.obs;

  Future<void> toggle() async {
    final c = call.value;
    if (c != null) {
      await c.hangup();
      return;
    }
    if (checking.value) return;
    checking.value = true;
    final ok = await vantarisPeerSupportsDraw(ffi.sessionId);
    checking.value = false;
    if (!ok) {
      VantarisCall.lastEndReason = 'sin cliente Vantaris';
      showToast('Este equipo no tiene el cliente Vantaris: no se puede hacer videollamada.');
      return;
    }
    if (!vantarisPeerHas(ffi.sessionId, 'call')) {
      VantarisCall.lastEndReason = 'cliente antiguo (sin «call»)';
      showToast('El cliente Vantaris de este equipo es antiguo: actualízalo para la videollamada.');
      return;
    }
    final id = Random().nextInt(1 << 30).toRadixString(36);
    final nc = VantarisCall(
      id: id,
      caller: true,
      sendLine: (l) => bind.sessionSendChat(
          sessionId: ffi.sessionId, text: kVantarisDrawPrefix + l),
      onEnded: (x) {
        if (call.value == x) call.value = null;
      },
    );
    call.value = nc;
    await nc.start();
  }

  void onLine(String line) {
    final d = _decodeLine(line);
    if (d == null) return;
    final c = call.value;
    if (c != null && c.id == d.$1) c.onMessage(d.$2);
  }
}

/// Técnico: línea «V …» que llega del equipo.
void vantarisCallFromPeer(SessionID sid, String line) =>
    VantarisCallState._states[sid]?.onLine(line);

/// Panel flotante de la videollamada en la vista remota del técnico.
class VantarisCallPanel extends StatefulWidget {
  final FFI ffi;
  const VantarisCallPanel({Key? key, required this.ffi}) : super(key: key);

  @override
  State<VantarisCallPanel> createState() => _VantarisCallPanelState();
}

class _VantarisCallPanelState extends State<VantarisCallPanel> {
  Offset _pos = const Offset(24, 80);

  @override
  Widget build(BuildContext context) {
    final state = VantarisCallState.of(widget.ffi);
    return Obx(() {
      final c = state.call.value;
      if (c == null) return const Offstage();
      return Positioned(
        left: _pos.dx,
        top: _pos.dy,
        child: GestureDetector(
          onPanUpdate: (d) => setState(() => _pos += d.delta),
          child: Material(
            elevation: 8,
            color: Colors.black,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 360, height: 318, child: _CallBody(call: c, compact: true)),
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------- vista común

class _CallBody extends StatelessWidget {
  final VantarisCall call;
  final bool compact;
  const _CallBody({required this.call, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final small = compact ? const Size(96, 72) : const Size(140, 105);
    return Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: Obx(() => call.hasRemoteVideo.isTrue
                ? RTCVideoView(call.remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                : const Center(
                    child: Icon(Icons.person, color: Colors.white24, size: 72))),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            width: small.width,
            height: small.height,
            child: Obx(() => call.hasLocalVideo.isTrue && call.camOn.isTrue
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: RTCVideoView(call.localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
                : const SizedBox.shrink()),
          ),
          Positioned(
            left: 8,
            top: 8,
            right: 8,
            child: Obx(() => call.status.value.isEmpty
                ? const SizedBox.shrink()
                : Text(call.status.value,
                    style: const TextStyle(color: Colors.white, fontSize: 14))),
          ),
        ]),
      ),
      Container(
        color: const Color(0xFF151B26),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Obx(() => IconButton(
                tooltip: call.micOn.isTrue ? 'Silenciar micrófono' : 'Activar micrófono',
                icon: Icon(call.micOn.isTrue ? Icons.mic : Icons.mic_off,
                    color: Colors.white),
                onPressed: call.toggleMic,
              )),
          Obx(() => IconButton(
                tooltip: call.camOn.isTrue ? 'Apagar cámara' : 'Encender cámara',
                icon: Icon(call.camOn.isTrue ? Icons.videocam : Icons.videocam_off,
                    color: Colors.white),
                onPressed: call.toggleCam,
              )),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
            icon: const Icon(Icons.call_end),
            label: const Text('Colgar'),
            onPressed: () => call.hangup(),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- lado controlado

VantarisCall? _incoming;
final _earlyIce = <String, List<Map<String, dynamic>>>{};

/// Equipo controlado: línea «V …» que manda el técnico por la conexión [connId].
void vantarisCallFromController(int connId, String line) {
  final d = _decodeLine(line);
  if (d == null) return;
  final (id, m) = d;
  void sendLine(String l) => bind.cmSendChat(connId: connId, msg: kVantarisDrawPrefix + l);
  final current = _incoming;
  if (m['t'] == 'offer') {
    if (current != null) {
      for (final l in _encode(id, {'t': 'decline', 'busy': true})) {
        sendLine(l);
      }
      return;
    }
    _ring(id, m, connId, sendLine);
    return;
  }
  if (current != null && current.id == id) {
    current.onMessage(m);
  } else if (m['t'] == 'ice') {
    // Candidatos que llegan mientras el usuario decide si acepta.
    _earlyIce.putIfAbsent(id, () => []).add(m);
  } else if (m['t'] == 'bye') {
    _earlyIce.remove(id);
    final ctx = globalKey.currentContext;
    if (_ringing == id && ctx != null) Navigator.of(ctx).maybePop();
  }
}

String? _ringing;

Future<void> _ring(String id, Map<String, dynamic> offer, int connId,
    void Function(String) sendLine) async {
  _ringing = id;
  if (isAndroid) {
    gFFI.invokeMethod('vantaris_front');
    await Future.delayed(const Duration(milliseconds: 600));
  }
  final ctx = globalKey.currentContext;
  if (ctx == null) {
    for (final l in _encode(id, {'t': 'decline'})) {
      sendLine(l);
    }
    return;
  }
  final accepted = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) {
          Timer(_kRingTimeout, () {
            if (_ringing == id) Navigator.of(c).maybePop(false);
          });
          return AlertDialog(
            title: const Text('Videollamada del técnico'),
            content: const Text('El técnico de Vantaris quiere hacer una videollamada.\n'
                'Se usarán la cámara y el micrófono de este equipo.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(c).pop(false), child: const Text('Rechazar')),
              ElevatedButton(
                  onPressed: () => Navigator.of(c).pop(true), child: const Text('Aceptar')),
            ],
          );
        },
      ) ??
      false;
  _ringing = null;
  if (!accepted) {
    _earlyIce.remove(id);
    for (final l in _encode(id, {'t': 'decline'})) {
      sendLine(l);
    }
    return;
  }
  if (isAndroid) {
    await AndroidPermissionManager.request('android.permission.CAMERA');
  }
  final call = VantarisCall(
    id: id,
    caller: false,
    sendLine: sendLine,
    onEnded: (x) {
      if (_incoming == x) _incoming = null;
      gFFI.serverModel.removeListener(_watchConnection);
      final c = globalKey.currentContext;
      if (c != null && _pageOpen) {
        Navigator.of(c).popUntil((r) => r.settings.name != _kCallRoute);
      }
    },
  );
  _incoming = call;
  _callConnId = connId;
  gFFI.serverModel.addListener(_watchConnection);
  await call.accept(offer);
  for (final m in _earlyIce.remove(id) ?? []) {
    await call.onMessage(m);
  }
  final c2 = globalKey.currentContext;
  if (c2 != null && _incoming == call) {
    _pageOpen = true;
    await Navigator.of(c2).push(MaterialPageRoute(
        settings: const RouteSettings(name: _kCallRoute),
        builder: (_) => _CallPage(call: call)));
    _pageOpen = false;
  }
}

const _kCallRoute = 'vantaris-videollamada';
int _callConnId = -1;
bool _pageOpen = false;

// Si se cae la conexión de RustDesk, se cuelga también la videollamada.
void _watchConnection() {
  final alive = gFFI.serverModel.clients
      .any((c) => c.id == _callConnId && c.authorized && !c.disconnected);
  if (!alive) _incoming?.hangup(notify: false, reason: 'El técnico se ha desconectado.');
}

class _CallPage extends StatelessWidget {
  final VantarisCall call;
  const _CallPage({required this.call});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) call.hangup();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: const Color(0xFF151B26),
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          title: const Text('Videollamada con el técnico de Vantaris'),
        ),
        body: SafeArea(child: _CallBody(call: call)),
      ),
    );
  }
}
