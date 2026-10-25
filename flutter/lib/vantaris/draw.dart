// Vantaris: dibujar sobre la pantalla del equipo controlado para señalar cosas al usuario.
//
// Los trazos viajan por el canal de chat ya existente de la sesión, con un prefijo invisible
// que los separa de los mensajes normales. Así no hace falta tocar la librería Rust ni el
// protocolo: vale con que los dos extremos sean clientes Vantaris.
// El lado controlado los pinta en una capa transparente que no bloquea toques ni ratón
// (Android: VantarisDrawOverlay.kt; Windows: windows/runner/vantaris_overlay.cpp).
//
// Formato del cuerpo: una orden por línea, coordenadas normalizadas 0..10000.
//   D <x> <y> <ancho> <alto>          pantalla remota que ve el técnico, en píxeles del equipo
//                                     (solo la usa Windows, que puede tener varios monitores)
//   P <id> <argb hex> <grosor ‰> x,y x,y ...   añade puntos a un trazo
//   E <id>                            fin de trazo (se desvanece a los 6 s)
//   C                                 borra todo
//   L x,y | L -                       láser: mueve el punto / lo apaga (se apaga solo a los 1,5 s)
//   S <id> <forma> <argb> <grosor ‰> x,y x,y   forma A flecha, R rectángulo, O elipse,
//                                     T triángulo, I línea; se repite con el mismo id al arrastrar
//   N <id> <argb> <número> x,y        número de paso (círculo con cifra)
//   X <id> <argb> x,y <base64url>     texto
//   E <id> [ms]                       fin de elemento; [ms] = tiempo visible antes de desvanecerse
//   Z <id>                            quita un elemento (deshacer)
//   F x,y x,y | F -                   foco: oscurece todo menos ese rectángulo / lo quita
// Sin E un elemento no caduca: así funciona «fijar» (el técnico manda E al desfijar).
// Los clientes antiguos ignoran las órdenes que no conocen.

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'call.dart';
import 'diag.dart';
import 'diag_panel.dart';
import 'guard.dart';
import 'marca.dart';
import 'permiso_pizarra.dart';
import 'scene.dart';

const String kVantarisDrawPrefix = '\u0001VTD1\n';

bool isVantarisDrawMessage(String text) => text.startsWith(kVantarisDrawPrefix);

// Saludo previo: el técnico manda 'H' y solo un cliente Vantaris contesta 'OK'. Sin respuesta
// no se dibuja, para no llenar de mensajes ilegibles el chat de un RustDesk normal.
final _supported = <String, Completer<bool>>{};
final _caps = <String, Set<String>>{};

/// Qué sabe hacer el cliente Vantaris del otro lado (tras vantarisPeerSupportsDraw).
/// «call»: videollamada; «diag»: diagnóstico y acciones rápidas. Los clientes anteriores
/// contestan «OK» a secas.
bool vantarisPeerHas(SessionID sessionId, String cap) =>
    _caps[sessionId.toString()]?.contains(cap) ?? false;

/// Llega un mensaje del lápiz por el chat. [connId] es la conexión (lado controlado) o
/// ChatModel.clientModeID en el lado técnico, con [sessionId] de su sesión.
void onVantarisDrawMessage(String text,
    {required int connId, required bool fromController, SessionID? sessionId}) {
  final body = text.substring(kVantarisDrawPrefix.length);
  if (body == 'OK' || body.startsWith('OK ')) {
    if (!fromController && sessionId != null) {
      _caps[sessionId.toString()] = body.split(' ').skip(1).toSet();
      final c = _supported.putIfAbsent(sessionId.toString(), () => Completer());
      if (!c.isCompleted) c.complete(true);
    }
    return;
  }
  if (!fromController) {
    // Del equipo al técnico: respuestas del modo «no tocar».
    if (sessionId != null) {
      if (body.startsWith('V ')) {
        vantarisCallFromPeer(sessionId, body);
      } else if (body.startsWith('q ')) {
        vantarisDiagFromPeer(sessionId, body);
      } else if (body.startsWith('k ')) {
        vantarisLogoFromPeer(body);
      } else if (body.startsWith('w ')) {
        vantarisPermisoCapaFromPeer(body);
      } else {
        vantarisGuardFromPeer(sessionId, body);
      }
    }
    return; // solo se pinta lo que manda el técnico
  }
  if (body == 'H') {
    // Solo contesta quien sabe pintar (Linux/macOS controlados: sin capa todavía).
    if (isAndroid || isWindows) {
      bind.cmSendChat(connId: connId, msg: '${kVantarisDrawPrefix}OK call diag logo red');
    }
    return;
  }
  if (body.startsWith('V ')) {
    // Videollamada: siempre llega en mensajes propios (ver call.dart).
    if (isAndroid || isWindows) vantarisCallFromController(connId, body);
    return;
  }
  if (body.startsWith('K ')) {
    // Color del logo de Vantaris en el equipo (ver marca.dart).
    vantarisLogoFromController(connId, body);
    return;
  }
  if (body.startsWith('Q ')) {
    // Diagnóstico y acciones rápidas del técnico (lista cerrada, ver diag.dart).
    if (isAndroid || isWindows) vantarisDiagFromController(connId, body);
    return;
  }
  if (isAndroid) {
    // El modo «no tocar» va aparte; lo demás es dibujo.
    final draw = <String>[];
    for (final line in body.split('\n')) {
      if (line.startsWith('B ')) {
        vantarisGuardBlock(line.trim() == 'B 1');
      } else if (line.startsWith('R ')) {
        vantarisGuardRecording(line.trim() == 'R 1');
      } else {
        draw.add(line);
      }
    }
    if (draw.isNotEmpty) {
      // false = falta «Mostrar sobre otras apps» (ver permiso_pizarra.dart).
      gFFI.invokeMethod('vantaris_draw', draw.join('\n')).then((ok) {
        if (ok == false) vantarisSinPermisoCapa(connId);
      });
    }
  } else if (isWindows) {
    _hostChannel.invokeMethod('vantarisOverlay', body);
  }
}

const _hostChannel = MethodChannel('org.rustdesk.rustdesk/host');

/// Lado técnico: ¿el equipo remoto es un cliente Vantaris? Pregunta una vez por sesión.
Future<bool> vantarisPeerSupportsDraw(SessionID sessionId) async {
  final key = sessionId.toString();
  var c = _supported[key];
  if (c == null) {
    c = Completer<bool>();
    _supported[key] = c;
    bind.sessionSendChat(sessionId: sessionId, text: '${kVantarisDrawPrefix}H');
  }
  try {
    return await c.future.timeout(const Duration(seconds: 4));
  } on TimeoutException {
    _supported.remove(key); // se podrá volver a preguntar
    return false;
  }
}

void vantarisForgetSession(SessionID sessionId) =>
    _supported.remove(sessionId.toString());

/// Colores del lápiz, en el orden en que aparecen en la barra.
const List<Color> kVantarisDrawColors = [
  Color(0xFFE53935), // rojo
  Color(0xFFFFD600), // amarillo
  Color(0xFF03B5A5), // teal Vantaris
  Color(0xFF1E88E5), // azul
];

/// Solo pruebas (demo.dart, VANTARIS_DEMO_OVERLAY): copia de todo lo que se manda al equipo.
void Function(String body)? vantarisDebugTee;

/// Grosores del lápiz y las formas, en milésimas del lado corto de la pantalla remota.
const List<int> kVantarisDrawWidths = [3, 6, 12];

/// Lado técnico: manda las órdenes agrupadas cada ~40 ms para no saturar la conexión y las
/// aplica a la vez en [scene], que es lo que ve el técnico.
class VantarisDrawSender {
  final SessionID sessionId;
  VantarisDrawSender(this.sessionId);

  final VantarisScene scene = VantarisScene();

  /// Se llama cuando cambia la escena local (para repintar).
  VoidCallback? onChanged;

  Color color = kVantarisDrawColors.first;
  int widthPermille = 6;

  /// Fijar: los elementos no caducan hasta desfijar o borrar.
  bool _pinned = false;
  final _pinnedIds = <String>[];

  /// Pantalla remota que se está viendo (coordenadas del equipo remoto).
  Rect? displayRect;
  String? _laser;

  final _pending = <String>[];
  final _points = <String>[];
  String? _strokeId;
  String? _shapeLine; // última forma en curso (solo se manda la última de cada tanda)
  String? _shapeId;
  final _history = <String>[]; // ids en orden, para deshacer
  int _number = 1;
  Timer? _timer;
  int _seq = 0;
  final _rand = Random().nextInt(1 << 20).toRadixString(36);

  static String _coord(double v) => (v.clamp(0.0, 1.0) * 10000).round().toString();
  static String _pt(Offset n) => '${_coord(n.dx)},${_coord(n.dy)}';
  String get _argb => color.value.toRadixString(16).padLeft(8, '0');
  String _newId() => '$_rand${_seq++}';

  int get nextNumber => _number;
  bool get pinned => _pinned;

  void _local(String line) {
    scene.apply(line);
    onChanged?.call();
  }

  /// Fin de un elemento: caduca salvo que esté fijado.
  void _finish(String id, {int? holdMs}) {
    _history.add(id);
    if (_pinned) {
      _pinnedIds.add(id);
      return;
    }
    final line = holdMs == null ? 'E $id' : 'E $id $holdMs';
    _local(line);
    _pending.add(line);
  }

  // ---- Lápiz ----

  /// [x] e [y] normalizados 0..1 sobre la pantalla remota.
  void start(double x, double y) {
    _flushPoints();
    _strokeId = _newId();
    _addPoint(x, y);
  }

  void move(double x, double y) {
    if (_strokeId == null) return;
    _addPoint(x, y);
  }

  void _addPoint(double x, double y) {
    final p = '${_coord(x)},${_coord(y)}';
    _points.add(p);
    _local('P $_strokeId $_argb $widthPermille $p');
    _schedule();
  }

  void end() {
    if (_strokeId != null) {
      _flushPoints();
      _finish(_strokeId!);
      _strokeId = null;
    }
    endShape();
    _flush();
  }

  // ---- Formas ----

  /// Crea o actualiza la forma en curso mientras se arrastra de [a] a [b].
  void shape(VantarisShape kind, Offset a, Offset b) {
    _shapeId ??= _newId();
    final line = 'S $_shapeId ${vantarisShapeCode(kind)} $_argb $widthPermille '
        '${_pt(a)} ${_pt(b)}';
    _shapeLine = line;
    _local(line);
    _schedule();
  }

  void endShape() {
    final id = _shapeId;
    if (id == null) return;
    if (_shapeLine != null) {
      _pending.add(_shapeLine!);
      _shapeLine = null;
    }
    _shapeId = null;
    _finish(id);
    _flush();
  }

  // ---- Números y texto ----

  void number(Offset at) {
    final id = _newId();
    final line = 'N $id $_argb ${_number++} ${_pt(at)}';
    _local(line);
    _pending.add(line);
    _finish(id, holdMs: kVantarisHoldMarkMs);
    _flush();
  }

  void text(Offset at, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final id = _newId();
    final line = 'X $id $_argb ${_pt(at)} ${vantarisEncodeText(t)}';
    _local(line);
    _pending.add(line);
    _finish(id, holdMs: kVantarisHoldMarkMs);
    _flush();
  }

  // ---- Foco ----

  void focus(Offset a, Offset b) {
    final line = 'F ${_pt(a)} ${_pt(b)}';
    _local(line);
    _pending.removeWhere((l) => l.startsWith('F '));
    _pending.add(line);
    _schedule();
  }

  void focusOff() {
    _local('F -');
    _pending.add('F -');
    _flush();
  }

  // ---- Láser ----

  /// Láser: solo se manda la última posición de cada tanda.
  void laser(double x, double y) {
    _laser = 'L ${_coord(x)},${_coord(y)}';
    _local(_laser!);
    _schedule();
  }

  void laserOff() {
    _laser = null;
    _local('L -');
    _pending.add('L -');
    _flush();
  }

  // ---- Fijar, deshacer, borrar ----

  void setPinned(bool on) {
    if (_pinned == on) return;
    _pinned = on;
    if (!on) {
      for (final id in _pinnedIds) {
        _local('E $id');
        _pending.add('E $id');
      }
      _pinnedIds.clear();
      _flush();
    }
  }

  void undo() {
    if (_history.isEmpty) return;
    final id = _history.removeLast();
    _pinnedIds.remove(id);
    _local('Z $id');
    _pending.add('Z $id');
    _flush();
  }

  void clear() {
    _points.clear();
    _strokeId = null;
    _shapeId = null;
    _shapeLine = null;
    _history.clear();
    _pinnedIds.clear();
    _number = 1;
    _local('C');
    _pending.add('C');
    _flush();
  }

  void _flushPoints() {
    if (_strokeId == null || _points.isEmpty) return;
    _pending.add('P $_strokeId $_argb $widthPermille ${_points.join(' ')}');
    _points.clear();
  }

  void _schedule() {
    _timer ??= Timer(const Duration(milliseconds: 40), () {
      _timer = null;
      _flushPoints();
      if (_shapeLine != null) {
        _pending.add(_shapeLine!);
        _shapeLine = null;
      }
      if (_laser != null) {
        _pending.add(_laser!);
        _laser = null;
      }
      _flush();
    });
  }

  void _flush() {
    if (_pending.isEmpty) return;
    final r = displayRect;
    if (r != null) {
      _pending.insert(0,
          'D ${r.left.round()} ${r.top.round()} ${r.width.round()} ${r.height.round()}');
    }
    final body = _pending.join('\n');
    final text = kVantarisDrawPrefix + body;
    _pending.clear();
    vantarisDebugTee?.call(body);
    bind.sessionSendChat(sessionId: sessionId, text: text);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    onChanged = null;
  }
}
