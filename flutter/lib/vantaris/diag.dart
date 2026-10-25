// Vantaris: diagnóstico del equipo y acciones rápidas del técnico (ver diag_panel.dart).
//
// El técnico pide y el equipo contesta por el canal de la pizarra (draw.dart):
//   Q <petición> <orden> [arg]     técnico -> equipo. Órdenes de una LISTA CERRADA:
//                                  estado · registros · prueba <impresora> · cajon · reiniciar
//                                  y las de red.dart (sin TPV): red · ping · imprimirip · cajonip ·
//                                  impresoras · imprimirlocal · cajonlocal
//   q <petición> <i>/<n> <trozo>   equipo -> técnico: JSON en base64url, troceado
// No hay forma de mandar otra cosa: una orden que no está en la lista se contesta con error.
//
// Quién hace el trabajo en el equipo:
//   - Android: VantarisDiag.kt (datos del sistema) + el TPV por su ContentProvider
//     «<paquete>.soporte», que solo atiende a este cliente firmado con la clave de Vantaris.
//   - Windows: aquí mismo (la ventana de conexión corre como el usuario) + el runner para
//     batería/disco/red (vantaris_diag.cpp) + el TPV por su puerta local 127.0.0.1 con el
//     token de «%USERPROFILE%\.vantaris\soporte-local.json».

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../common.dart';
import '../models/platform_model.dart';
import 'draw.dart';
import 'red.dart';

/// Órdenes que se aceptan (la lista blanca).
const kVantarisDiagOrders = {'estado', 'registros', 'prueba', 'cajon', 'reiniciar', ...kVantarisRedOrders};

/// Argumento válido para [orden]: las del TPV, un número (o nada); las de red, lo que diga red.dart.
bool _argValido(String orden, String? arg) => kVantarisRedOrders.contains(orden)
    ? vantarisRedArgValido(orden, arg)
    : arg == null || RegExp(r'^[0-9]{1,12}$').hasMatch(arg);

const _kChunk = 16000;

// ---------------------------------------------------------------- troceado

List<String> vantarisDiagEncode(String rid, Map<String, dynamic> msg) {
  final b = base64Url.encode(utf8.encode(jsonEncode(msg))).replaceAll('=', '');
  final n = max(1, (b.length / _kChunk).ceil());
  return [
    for (var i = 0; i < n; i++)
      'q $rid ${i + 1}/$n ${b.substring(i * _kChunk, min(b.length, (i + 1) * _kChunk))}'
  ];
}

class VantarisDiagAssembler {
  final _parts = <String, List<String?>>{};

  /// Junta los trozos; devuelve (petición, respuesta) cuando está completa.
  (String, Map<String, dynamic>)? add(String line) {
    final p = line.trim().split(' ');
    if (p.length < 4 || p[0] != 'q') return null;
    final rid = p[1];
    final idx = p[2].split('/');
    final i = int.tryParse(idx[0]), n = int.tryParse(idx.length > 1 ? idx[1] : '');
    if (i == null || n == null || i < 1 || i > n || n > 2000) return null;
    final list = _parts.putIfAbsent(rid, () => List<String?>.filled(n, null));
    if (list.length != n) return null;
    list[i - 1] = p[3];
    if (list.any((e) => e == null)) return null;
    _parts.remove(rid);
    var b = list.join();
    while (b.length % 4 != 0) {
      b += '=';
    }
    try {
      return (rid, jsonDecode(utf8.decode(base64Url.decode(b))) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Cuántos trozos han llegado de [rid] (para la barra de progreso).
  (int, int)? progress(String rid) {
    final l = _parts[rid];
    if (l == null) return null;
    return (l.where((e) => e != null).length, l.length);
  }

  void forget(String rid) => _parts.remove(rid);
}

// ---------------------------------------------------------------- lado controlado

final _busy = <String>{};

/// Equipo controlado: línea «Q …» del técnico por la conexión [connId].
void vantarisDiagFromController(int connId, String line) {
  final p = line.trim().split(' ');
  if (p.length < 3 || p[0] != 'Q') return;
  final rid = p[1];
  final orden = p[2];
  final arg = p.length > 3 ? p[3] : null;
  if (!RegExp(r'^[a-z0-9]{1,24}$').hasMatch(rid)) return;
  final key = '$connId/$rid';
  if (!_busy.add(key)) return;
  () async {
    Map<String, dynamic> r;
    try {
      if (!kVantarisDiagOrders.contains(orden) || !_argValido(orden, arg)) {
        r = {'ok': false, 'motivo': 'Orden no permitida.'};
      } else if (kVantarisRedOrders.contains(orden)) {
        r = await vantarisRedRun(orden, arg); // igual en Android y Windows, sin el TPV
      } else if (isAndroid) {
        final s = await platformFFI.invokeMethod(
            'vantaris_diag', jsonEncode({'orden': orden, if (arg != null) 'arg': arg}));
        r = jsonDecode(s as String) as Map<String, dynamic>;
      } else if (isWindows) {
        r = await _windowsRun(orden, arg);
      } else {
        r = {'ok': false, 'motivo': 'Este equipo todavía no tiene diagnóstico.'};
      }
    } catch (e) {
      r = {'ok': false, 'motivo': 'Fallo en el equipo: $e'};
    }
    r['orden'] = orden;
    final lines = vantarisDiagEncode(rid, r);
    for (var i = 0; i < lines.length; i++) {
      bind.cmSendChat(connId: connId, msg: kVantarisDrawPrefix + lines[i]);
      // Sin prisas: los registros pueden ser cientos de trozos y la sesión sigue viva.
      if (lines.length > 1) await Future.delayed(const Duration(milliseconds: 15));
    }
    _busy.remove(key);
  }();
}

// ---------------------------------------------------------------- Windows

const _hostChannel = MethodChannel('org.rustdesk.rustdesk/host');

Future<Map<String, dynamic>> _windowsRun(String orden, String? arg) async {
  switch (orden) {
    case 'estado':
      return _windowsEstado();
    case 'registros':
      return _windowsRegistros();
    case 'prueba':
      return _tpv('POST', '/prueba?id=$arg');
    case 'cajon':
      return _tpv('POST', '/cajon');
    case 'reiniciar':
      return _tpv('POST', '/reiniciar');
  }
  return {'ok': false, 'motivo': 'Orden no permitida.'};
}

Future<Map<String, dynamic>> _windowsEstado() async {
  Map<String, dynamic> equipo = {};
  try {
    final s = await _hostChannel.invokeMethod<String>('vantarisSysInfo');
    if (s != null) equipo = jsonDecode(s) as Map<String, dynamic>;
  } catch (_) {}
  equipo['so'] ??= 'Windows ${Platform.operatingSystemVersion}';
  final res = await Future.wait([_servidor(), _tpv('GET', '/estado')]);
  final tpv = res[1];
  return {'ok': true, 'plataforma': 'windows', 'equipo': equipo, 'servidor': res[0], 'tpv': tpv};
}

Future<Map<String, dynamic>> _windowsRegistros() async {
  final lista = await _tpv('GET', '/registros');
  if (lista['ok'] != true) return lista;
  final out = <Map<String, dynamic>>[];
  for (final a in (lista['arranques'] as List? ?? [])) {
    final m = Map<String, dynamic>.from(a as Map);
    final bytes = await _tpvBytes('/registro?id=${Uri.encodeQueryComponent('${m['id']}')}');
    if (bytes == null) continue;
    m['gz'] = base64.encode(bytes);
    out.add(m);
  }
  return {'ok': true, 'arranques': out};
}

/// ¿Llega este equipo al servidor de Vantaris? Cualquier respuesta HTTP vale.
Future<Map<String, dynamic>> _servidor() async {
  final sw = Stopwatch()..start();
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await c.headUrl(Uri.parse('https://api.vantaris.es/'));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    await resp.drain<void>();
    return {'llega': true, 'ms': sw.elapsedMilliseconds, 'host': 'api.vantaris.es'};
  } catch (e) {
    return {'llega': false, 'host': 'api.vantaris.es', 'error': '$e'.split('\n').first};
  } finally {
    c.close(force: true);
  }
}

Map<String, dynamic>? _puerta() {
  try {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final f = File('$home${Platform.pathSeparator}.vantaris${Platform.pathSeparator}soporte-local.json');
    if (!f.existsSync()) return null;
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

const _sinPuerta = {
  'ok': false,
  'puerta': false,
  'motivo': 'La app TPV no está abierta en este equipo (o es una versión sin diagnóstico remoto).'
};

Future<HttpClientResponse?> _tpvRequest(String method, String path) async {
  final p = _puerta();
  if (p == null) return null;
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:${p['puerto']}$path'));
  req.headers.set('Authorization', 'Bearer ${p['token']}');
  return req.close().timeout(const Duration(seconds: 30));
}

Future<Map<String, dynamic>> _tpv(String method, String path) async {
  try {
    final r = await _tpvRequest(method, path);
    if (r == null) return Map.of(_sinPuerta);
    final body = await r.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    return Map.of(_sinPuerta);
  }
}

Future<List<int>?> _tpvBytes(String path) async {
  try {
    final r = await _tpvRequest('GET', path);
    if (r == null || r.statusCode != 200) return null;
    final b = BytesBuilder();
    await for (final chunk in r) {
      b.add(chunk);
    }
    return b.takeBytes();
  } catch (_) {
    return null;
  }
}
