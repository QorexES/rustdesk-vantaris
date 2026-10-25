// Vantaris: demostración automática de la pizarra y del modo «no tocar» (lado técnico).
// Solo se activa arrancando el técnico con la variable de entorno VANTARIS_DEMO=1: al conectar,
// recorre todas las herramientas contra el equipo remoto. Sirve para probar un cliente nuevo sin
// tener que dibujar a mano (y para grabar vídeos de muestra).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../models/input_model.dart';
import '../models/model.dart';
import 'call.dart';
import 'capture.dart';
import 'diag_panel.dart';
import 'draw.dart';
import 'draw_layer.dart';
import 'guard.dart';
import 'quick_replies.dart';
import 'scene.dart';
import 'summary.dart';

bool get vantarisDemoEnabled {
  try {
    return Platform.environment['VANTARIS_DEMO'] == '1';
  } catch (_) {
    return false;
  }
}

final _started = <SessionID>{};

/// Se llama al abrir la sesión remota; si la demo está activada, arranca a los pocos segundos.
void vantarisMaybeRunDemo(FFI ffi) {
  if (!vantarisDemoEnabled || !_started.add(ffi.sessionId)) return;
  Timer(const Duration(seconds: 8), () => _run(ffi));
}

/// Registro de la demo en %TEMP%\vantaris-demo.log (en release no hay consola).
void _log(String msg) {
  try {
    final tmp = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    File('$tmp${Platform.pathSeparator}vantaris-demo.log')
        .writeAsStringSync('${DateTime.now()} $msg\n', mode: FileMode.append);
  } catch (_) {}
}

Future<void> _wait(int ms) => Future.delayed(Duration(milliseconds: ms));

Future<void> _run(FFI ffi) async {
  _log('demo: empieza contra ${ffi.id}');
  // VANTARIS_DEMO_DIAG=1: solo el diagnóstico (panel + registros). Con VANTARIS_DEMO_DIAG_ACCIONES=1
  // además ticket de prueba en la primera impresora y cajón; con VANTARIS_DEMO_DIAG_REINICIAR=1,
  // reinicio de la app TPV. Sin pedir confirmación: es solo para pruebas.
  if (Platform.environment['VANTARIS_DEMO_DIAG'] == '1') {
    await _runDiag(ffi);
    return;
  }
  // VANTARIS_DEMO_CALL=1: solo la videollamada (hay que aceptarla en el equipo).
  if (Platform.environment['VANTARIS_DEMO_CALL'] == '1') {
    final cs = VantarisCallState.of(ffi);
    await cs.toggle();
    for (var i = 0; i < 60; i++) {
      await _wait(1000);
      final c = cs.call.value;
      _log('videollamada t=$i: ${c == null ? 'terminada' : 'conectada=${c.connected.value} '
          'video remoto=${c.hasRemoteVideo.value} video local=${c.hasLocalVideo.value} '
          'estado=«${c.status.value}»'}');
      if (c == null) {
        _log('videollamada: motivo del final: ${VantarisCall.lastEndReason}');
        return;
      }
      if (c.connected.isTrue && i > 25) break;
    }
    await cs.call.value?.hangup();
    _log('videollamada: colgada por la demo');
    return;
  }
  // VANTARIS_DEMO_CHAT=1: respuestas rápidas por el chat normal, también con el foco de la
  // pizarra y el «no tocar» puestos (el cliente Android tiene que ver la tarjeta del mensaje).
  if (Platform.environment['VANTARIS_DEMO_CHAT'] == '1') {
    await _chatDemo(ffi);
    return;
  }
  // VANTARIS_DEMO_OVERLAY=1: además pinta todo en la capa de ESTE equipo (Windows), para ver
  // el pintor C++ sin otro PC. Junto con VANTARIS_OVERLAY_CAPTURABLE=1 sale en las capturas.
  if (Platform.environment['VANTARIS_DEMO_OVERLAY'] == '1' && isWindows) {
    const ch = MethodChannel('es.vantaris/tecnico');
    vantarisDebugTee = (body) {
      final lines = body.split('\n').where((l) => !l.startsWith('D ')).join('\n');
      if (lines.isNotEmpty) ch.invokeMethod('overlay', lines);
    };
  }
  final draw = VantarisDrawState.of(ffi);
  if (!await vantarisPeerSupportsDraw(ffi.sessionId)) {
    _log('demo: el equipo no contesta como cliente Vantaris');
    debugPrint('VANTARIS_DEMO: el equipo no es cliente Vantaris');
    return;
  }
  // VANTARIS_DEMO_FONDO=1: «no tocar» puesto y un dibujo nuevo cada 4 s durante
  // VANTARIS_DEMO_FONDO_S segundos (240 por defecto), para comprobar que el equipo Android sigue
  // pintando y bloqueando con la app en segundo plano o cerrada.
  if (Platform.environment['VANTARIS_DEMO_FONDO'] == '1') {
    await _runFondo(ffi, draw);
    return;
  }
  // VANTARIS_DEMO_RESUMEN=1: además graba la asistencia y la manda al servicio de resumen.
  VantarisSummaryState? summary;
  if (Platform.environment['VANTARIS_DEMO_RESUMEN'] == '1' && isWindows) {
    summary = VantarisSummaryState.of(ffi);
    await summary.toggle();
    _log('resumen: grabando=${summary.recording.value}');
  }
  final s = draw.sender;
  s.displayRect = ffi.ffiModel.rect;
  void color(int i) => s.color = kVantarisDrawColors[i];

  // 1. Lápiz: una onda.
  color(0);
  s.start(0.10, 0.20);
  for (var i = 1; i <= 30; i++) {
    s.move(0.10 + i * 0.01, 0.20 + (i.isEven ? 0.03 : -0.03));
    await _wait(20);
  }
  s.end();
  // 2. Formas.
  const shapes = [
    (VantarisShape.arrow, Offset(0.45, 0.15), Offset(0.60, 0.30)),
    (VantarisShape.rect, Offset(0.65, 0.12), Offset(0.85, 0.30)),
    (VantarisShape.ellipse, Offset(0.10, 0.40), Offset(0.28, 0.60)),
    (VantarisShape.triangle, Offset(0.35, 0.40), Offset(0.50, 0.60)),
    (VantarisShape.line, Offset(0.55, 0.45), Offset(0.85, 0.55)),
  ];
  var ci = 0;
  for (final (kind, a, b) in shapes) {
    color(ci++ % kVantarisDrawColors.length);
    for (var t = 0.2; t <= 1.0001; t += 0.2) {
      s.shape(kind, a, Offset.lerp(a, b, t)!);
      await _wait(60);
    }
    s.endShape();
  }
  // 3. Números de paso y texto.
  color(2);
  s.number(const Offset(0.20, 0.75));
  s.number(const Offset(0.35, 0.75));
  s.number(const Offset(0.50, 0.75));
  color(1);
  s.text(const Offset(0.58, 0.75), 'Pulse aquí para cobrar');
  // 4. Láser.
  for (var i = 0; i <= 40; i++) {
    s.laser(0.15 + i * 0.015, 0.88);
    await _wait(40);
  }
  s.laserOff();
  try {
    final path = await vantarisCaptureAnnotated(ffi, s.scene); // Imágenes\Vantaris
    _log('captura: $path (portapapeles: $vantarisLastCaptureCopied)');
  } catch (e, st) {
    _log('captura falló: $e\n$st');
  }
  await _wait(4000); // captura: pizarra completa
  // 5. Foco.
  s.focus(const Offset(0.62, 0.10), const Offset(0.88, 0.32));
  await _wait(5000); // captura: foco
  s.focusOff();
  // 6. No tocar.
  final guard = VantarisGuardState.of(ffi);
  await guard.toggle();
  await _wait(5000); // captura: bloqueo
  // Con el bloqueo puesto, los clics del técnico tienen que seguir llegando.
  final r = ffi.ffiModel.rect;
  final x = double.tryParse(Platform.environment['VANTARIS_DEMO_X'] ?? '');
  final y = double.tryParse(Platform.environment['VANTARIS_DEMO_Y'] ?? '');
  if (r != null && x != null && y != null) {
    await ffi.inputModel.moveMouse(r.left + x * r.width, r.top + y * r.height);
    await ffi.inputModel.tap(MouseButtons.left);
    await _wait(4000); // captura: el clic del técnico ha cambiado algo
    await ffi.inputModel.tap(MouseButtons.left); // y lo deja como estaba
  }
  await _wait(6000);
  if (guard.blocking.isTrue) await guard.toggle();
  s.clear();
  if (summary != null) {
    // Sin await: si no hay audio útil, se queda el diálogo de «descartar» a la vista.
    summary.toggle(); // para y sube al servicio de resumen
    _log('resumen: grabación parada');
  }
  _log('demo: terminada');
  debugPrint('VANTARIS_DEMO: terminado');
}

Future<void> _runFondo(FFI ffi, VantarisDrawState draw) async {
  final secs =
      int.tryParse(Platform.environment['VANTARIS_DEMO_FONDO_S'] ?? '') ?? 240;
  final s = draw.sender;
  s.displayRect = ffi.ffiModel.rect;
  final guard = VantarisGuardState.of(ffi);
  if (guard.blocking.isFalse) await guard.toggle();
  _log('fondo: bloqueo=${guard.blocking.value}, $secs s');
  final end = DateTime.now().add(Duration(seconds: secs));
  var n = 0;
  while (DateTime.now().isBefore(end) && !ffi.closed) {
    n++;
    s.color = kVantarisDrawColors[n % kVantarisDrawColors.length];
    final dx = (n % 4) * 0.05;
    s.shape(VantarisShape.rect, Offset(0.25 + dx, 0.30), Offset(0.55 + dx, 0.55));
    s.endShape();
    s.text(const Offset(0.25, 0.62), 'Prueba en segundo plano $n');
    _log('fondo: dibujo $n (bloqueo=${guard.blocking.value})');
    await _wait(4000);
  }
  if (guard.blocking.isTrue) await guard.toggle();
  s.clear();
  _log('fondo: terminada tras $n dibujos');
}

Future<void> _chatDemo(FFI ffi) async {
  final replies = vantarisQuickReplies();
  String pick(int i) => replies.isEmpty ? 'Mensaje de prueba $i' : replies[i % replies.length];
  vantarisSendQuickReply(ffi.chatModel, pick(0), peerId: ffi.id);
  _log('chat: enviado «${pick(0)}»');
  await _wait(8000); // captura: mensaje solo
  if (!await vantarisPeerSupportsDraw(ffi.sessionId)) {
    _log('chat: el equipo no es cliente Vantaris; solo el chat');
    return;
  }
  final draw = VantarisDrawState.of(ffi);
  final s = draw.sender;
  s.displayRect = ffi.ffiModel.rect;
  s.focus(const Offset(0.55, 0.55), const Offset(0.90, 0.90));
  final guard = VantarisGuardState.of(ffi);
  await guard.toggle();
  await _wait(1500);
  vantarisSendQuickReply(ffi.chatModel, pick(1), peerId: ffi.id);
  _log('chat: enviado «${pick(1)}» con foco y no tocar');
  await _wait(10000); // captura: tarjeta encima del foco y del bloqueo
  s.focusOff();
  if (guard.blocking.isTrue) await guard.toggle();
  await _wait(1500);
  vantarisSendQuickReply(ffi.chatModel, pick(5), peerId: ffi.id);
  _log('chat: enviado «${pick(5)}»');
  await _wait(8000);
  _log('demo: terminada');
}

Future<void> _runDiag(FFI ffi) async {
  final ds = VantarisDiagState.of(ffi);
  final ctx = globalKey.currentContext;
  if (ctx != null) {
    // Abre el panel de verdad (para ver la interfaz); el resto no depende de él.
    unawaited(ds.toggle(ctx));
  } else {
    await vantarisPeerSupportsDraw(ffi.sessionId);
    await ds.refresh();
  }
  for (var i = 0; i < 60 && (ds.estado.value == null || ds.loading.isTrue); i++) {
    await _wait(500);
  }
  final e = ds.estado.value;
  _log('diag: estado = ${e == null ? 'sin respuesta' : jsonEncode(e)}');
  if (e != null) _log('diag: texto =\n${vantarisDiagText(e, ffi.id)}');
  await _wait(3000);
  final t0 = DateTime.now();
  await ds.fetchLogs();
  _log('diag: registros (${DateTime.now().difference(t0).inMilliseconds} ms) -> ${ds.last.value}');
  if (Platform.environment['VANTARIS_DEMO_DIAG_ACCIONES'] == '1') {
    final imps = ((e?['tpv'] as Map?)?['impresoras'] as List?) ?? [];
    if (imps.isNotEmpty) {
      final p = imps.first as Map;
      await ds.action('prueba', 'Ticket de prueba en «${p['nombre']}»', arg: '${p['id']}');
      _log('diag: prueba -> ${ds.last.value}');
    }
    await ds.action('cajon', 'Apertura del cajón portamonedas');
    _log('diag: cajon -> ${ds.last.value}');
    await ds.action('prueba', 'Ticket de prueba (impresora inexistente)', arg: '999999');
    _log('diag: prueba inexistente -> ${ds.last.value}');
  }
  if (Platform.environment['VANTARIS_DEMO_DIAG_REINICIAR'] == '1') {
    await ds.action('reiniciar', 'Reinicio de la app TPV');
    _log('diag: reiniciar -> ${ds.last.value}');
    await _wait(12000);
    await ds.refresh();
    _log('diag: estado tras reiniciar = ${jsonEncode(ds.estado.value)}');
  }
  _log('diag: fin');
}
