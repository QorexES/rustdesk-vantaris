// Vantaris: captura de la pantalla remota con lo dibujado encima (lado técnico, escritorio).
// Se guarda en «Imágenes\Vantaris» y, en Windows, se copia al portapapeles para pegarla en el
// ticket de Falcon con Ctrl+V.
//
// La imagen la pide la captura propia de RustDesk (sessionTakeScreenshot: el equipo remoto manda
// un PNG de su pantalla); en escritorio la vista remota es una textura y no se puede leer desde
// Dart. Cuando la respuesta es de una captura nuestra, FfiModel la entrega aquí
// (vantarisOnScreenshot) en vez de enseñar el diálogo de RustDesk.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common.dart';
import '../consts.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'scene.dart';

// Canal del runner de Windows en las ventanas de sesión (flutter_window.cpp).
const _tecnicoChannel = MethodChannel('es.vantaris/tecnico');

class _Pending {
  final ui.Picture drawing; // lo dibujado, pintado a [size]
  final Size size;
  final String peer;
  final bool swapRedBlue;
  final completer = Completer<String?>();
  _Pending(this.drawing, this.size, this.peer, this.swapRedBlue);
}

/// Resultado de la última copia al portapapeles (para la demo automática).
bool vantarisLastCaptureCopied = false;

// Las capturas que manda un Android llegan con el rojo y el azul cambiados (RustDesk 1.4.9).
const _swapRedBlue = ColorFilter.matrix(<double>[
  0, 0, 1, 0, 0, //
  0, 1, 0, 0, 0, //
  1, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
]);

final _pending = <SessionID, _Pending>{};

String _two(int v) => v.toString().padLeft(2, '0');

Directory _folder() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  return Directory('$home${Platform.pathSeparator}Pictures${Platform.pathSeparator}Vantaris');
}

/// Pide la captura y devuelve la ruta del PNG final (null si no se pudo).
Future<String?> vantarisCaptureAnnotated(FFI ffi, VantarisScene scene) async {
  final sid = ffi.sessionId;
  if (_pending.containsKey(sid)) return null; // ya hay una en marcha
  final supported = bind.sessionGetCommonSync(
      sessionId: sid, key: 'is_screenshot_supported', param: '');
  if (supported != 'true') {
    showToast('Este equipo no permite capturas (versión antigua).');
    return null;
  }
  if (ffi.ffiModel.pi.currentDisplay == kAllDisplayValue) {
    showToast('Elige una sola pantalla del equipo para hacer la captura.');
    return null;
  }
  final rect = ffi.ffiModel.rect;
  final size = (rect == null || rect.isEmpty) ? const Size(1920, 1080) : rect.size;
  // Lo dibujado se congela ya: la imagen tarda un poco en llegar y los trazos caducan.
  final recorder = ui.PictureRecorder();
  scene.paint(Canvas(recorder), Offset.zero & size);
  final p = _Pending(recorder.endRecording(), size, ffi.id,
      ffi.ffiModel.pi.platform == kPeerPlatformAndroid);
  _pending[sid] = p;
  showToast('Haciendo la captura…');
  bind.sessionTakeScreenshot(sessionId: sid, display: ffi.ffiModel.pi.currentDisplay);
  return p.completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
    _pending.remove(sid);
    showToast('El equipo no ha mandado la captura a tiempo.');
    return null;
  });
}

/// FfiModel llama aquí al llegar una captura. Devuelve true si era nuestra.
bool vantarisOnScreenshot(SessionID sid, String msg) {
  final p = _pending.remove(sid);
  if (p == null) return false;
  if (msg.isNotEmpty) {
    showToast('No se pudo hacer la captura: $msg');
    p.completer.complete(null);
    return true;
  }
  _finish(sid, p).then(p.completer.complete, onError: (e) {
    showToast('No se pudo guardar la captura: $e');
    p.completer.complete(null);
  });
  return true;
}

Future<String?> _finish(SessionID sid, _Pending p) async {
  final dir = _folder();
  await dir.create(recursive: true);
  final now = DateTime.now();
  final peer = p.peer.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
  final name = 'captura-$peer-${now.year}${_two(now.month)}${_two(now.day)}-'
      '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.png';
  final file = File('${dir.path}${Platform.pathSeparator}$name');

  // RustDesk guarda la imagen tal cual; luego se le pinta el dibujo encima.
  final raw = File('${Directory.systemTemp.path}${Platform.pathSeparator}vantaris-$name');
  final err = await bind.sessionHandleScreenshot(sessionId: sid, action: '0:${raw.path}');
  if (err.isNotEmpty) throw err;
  final codec = await ui.instantiateImageCodec(await raw.readAsBytes());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(
      image, Offset.zero, Paint()..colorFilter = p.swapRedBlue ? _swapRedBlue : null);
  // Android ya incluye la capa de dibujo en su captura (lo que ve el cliente); Windows la
  // excluye, así que ahí se pinta encima.
  if (!p.swapRedBlue) {
    canvas.scale(image.width / p.size.width, image.height / p.size.height);
    canvas.drawPicture(p.drawing);
  }
  final out = await recorder.endRecording().toImage(image.width, image.height);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  out.dispose();
  p.drawing.dispose();
  try {
    await raw.delete();
  } catch (_) {}
  if (data == null) throw 'sin datos';
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);

  var copied = false;
  if (isWindows) {
    try {
      copied = await _tecnicoChannel.invokeMethod<bool>('copyImage', file.path) ?? false;
    } catch (_) {}
  }
  vantarisLastCaptureCopied = copied;
  showToast(
      copied
          ? 'Captura copiada: pégala en el ticket con Ctrl+V (guardada en Imágenes\\Vantaris).'
          : 'Captura guardada en ${file.path}',
      timeout: const Duration(seconds: 5));
  return file.path;
}
