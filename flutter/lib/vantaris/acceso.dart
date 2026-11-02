// Vantaris: el técnico con sesión entra en los equipos SIN escribir contraseñas.
//
// Cada equipo dado de alta tiene su propia contraseña permanente, pero nadie la apunta ni la teclea:
// la calcula el servidor (soporte.vantaris.es/acceso/clave, deploy/pro/turn-credenciales) a partir del
// ID, y solo se la da a quien lleve una sesión válida de técnico de la consola Pro (las cuentas las
// creamos nosotros). Cada petición queda registrada con el técnico y el ID.
//
//   Técnico:  al pedir el equipo la contraseña («input-password»), se pide aquí y se entra sola.
//             Si falla (sin sesión, sin red, equipo dado de alta a mano con otra) sale el diálogo
//             de siempre. Vale para todas las entradas: ID, libreta, Falcon (rustdesk://), --connect.
//   Alta:     la tarjeta «Dar de alta» del equipo pide el usuario del instalador, inicia sesión un
//             momento, pide la contraseña de ESTE equipo, la aplica y cierra la sesión.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../common.dart';
import '../common/hbbs/hbbs.dart';
import '../models/platform_model.dart';

/// Cuándo se probó la contraseña del servidor en cada sesión: si el equipo la rechaza (vuelve a
/// pedirla enseguida) sale el diálogo normal y no se entra en bucle. Pasado un rato (reconexión tras
/// reiniciar el equipo) se vuelve a probar.
final Map<String, DateTime> _probadas = {};

Future<String?> _pedirClave(String api, String token, String id) async {
  try {
    final r = await http
        .post(Uri.parse('$api/acceso/clave'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'id': id.replaceAll(' ', '')}))
        .timeout(const Duration(seconds: 6));
    if (r.statusCode != 200) {
      debugPrint('Vantaris acceso: el servidor no da la clave (${r.statusCode})');
      return null;
    }
    final p = (jsonDecode(r.body) as Map)['password'];
    return p is String && p.isNotEmpty ? p : null;
  } catch (e) {
    debugPrint('Vantaris acceso: $e');
    return null;
  }
}

/// Contraseña del equipo [id] con la sesión de técnico de este programa, o null.
Future<String?> vantarisClaveEquipo(String id) async {
  final api = await bind.mainGetApiServer();
  final token = bind.mainGetLocalOption(key: 'access_token');
  if (api.isEmpty || token.isEmpty) return null;
  return _pedirClave(api, token, id);
}

/// Llamado cuando el equipo pide la contraseña. true = se ha intentado entrar con la del servidor
/// (no hay que enseñar el diálogo); false = enseñar el diálogo normal.
Future<bool> vantarisEntrarSinClave(SessionID sessionId, String peerId) async {
  final clave = sessionId.toString();
  final antes = _probadas[clave];
  if (antes != null && DateTime.now().difference(antes) < const Duration(seconds: 30)) {
    return false;
  }
  final pwd = await vantarisClaveEquipo(peerId);
  if (pwd == null) return false;
  _probadas[clave] = DateTime.now();
  await bind.sessionLogin(
      sessionId: sessionId, osUsername: '', osPassword: '', password: pwd, remember: false);
  return true;
}

/// Alta desde el propio equipo: inicia sesión con el usuario del instalador, pide la contraseña
/// de este equipo y cierra la sesión. Devuelve (contraseña, null) o (null, motivo del fallo).
Future<(String?, String?)> vantarisClaveParaAlta(String usuario, String password) async {
  final api = await bind.mainGetApiServer();
  if (api.isEmpty) return (null, 'Este programa no tiene servidor configurado.');
  final id = await bind.mainGetMyId();
  String token;
  try {
    final req = LoginRequest(
        username: usuario,
        password: password,
        id: id,
        uuid: await bind.mainGetUuid(),
        autoLogin: false,
        type: HttpType.kAuthReqTypeAccount);
    final r = await http
        .post(Uri.parse('$api/api/login'), body: jsonEncode(req.toJson()))
        .timeout(const Duration(seconds: 10));
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    if (r.statusCode != 200 || body['error'] != null) {
      return (null, 'Usuario o contraseña de técnico incorrectos.');
    }
    final t = body['access_token'];
    if (t is! String || t.isEmpty) {
      // Cuentas con verificación en dos pasos: el alta se hace por cable (provisionar-android.ps1).
      return (null, 'Esta cuenta pide verificación en dos pasos: dar de alta por cable.');
    }
    token = t;
  } catch (e) {
    return (null, 'Sin conexión con el servidor de soporte.');
  }
  final pwd = await _pedirClave(api, token, id);
  try {
    await http
        .post(Uri.parse('$api/api/logout'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
            body: jsonEncode({'id': id, 'uuid': await bind.mainGetUuid()}))
        .timeout(const Duration(seconds: 5));
  } catch (_) {}
  if (pwd == null) return (null, 'El servidor no ha dado la contraseña de este equipo.');
  return (pwd, null);
}
