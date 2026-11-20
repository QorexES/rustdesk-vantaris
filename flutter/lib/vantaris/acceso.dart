// Vantaris: el técnico con sesión entra en los equipos SIN escribir contraseñas.
//
// Cada equipo dado de alta tiene su propia contraseña permanente, pero nadie la apunta ni la teclea:
// la calcula el servidor (soporte.vantaris.es/acceso/clave, deploy/pro/turn-credenciales) a partir del
// ID, y solo se la da a quien lleve una sesión válida de técnico de la consola Pro (las cuentas las
// creamos nosotros). Cada petición queda registrada con el técnico y el ID.
//
//   Técnico:  al pedir el equipo la contraseña («input-password»), se pide aquí y se entra sola.
//             Si el equipo la rechaza, se prueban las genéricas de las instalaciones viejas que da el
//             mismo servidor («anteriores»; nunca van en el binario). Si tampoco (sin sesión, sin
//             red, equipo dado de alta a mano con otra) sale el diálogo de siempre. Vale para todas las entradas: ID, libreta, Falcon (rustdesk://), --connect.
//   Alta:     la tarjeta «Dar de alta» del equipo pide el usuario del instalador, inicia sesión un
//             momento, pide la contraseña de ESTE equipo, la aplica y cierra la sesión.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../common.dart';
import '../common/hbbs/hbbs.dart';
import '../models/platform_model.dart';

/// Contraseñas que quedan por probar en cada sesión y cuándo se probó la última: cada vez que el
/// equipo vuelve a pedirla enseguida (la ha rechazado) se prueba la siguiente; sin más, sale el
/// diálogo normal y no se entra en bucle. Pasado un rato (reconexión tras reiniciar el equipo) se
/// vuelve a empezar.
final Map<String, (List<String>, DateTime)> _pendientes = {};

/// Contraseña del equipo y, detrás, las genéricas antiguas, sin repetir.
Future<List<String>> _pedirClaves(String api, String token, String id) async {
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
      return [];
    }
    final m = jsonDecode(r.body) as Map;
    final todas = <String>[
      if (m['password'] is String) m['password'] as String,
      if (m['anteriores'] is List) ...(m['anteriores'] as List).whereType<String>(),
    ];
    return todas.where((c) => c.isNotEmpty).toSet().toList();
  } catch (e) {
    debugPrint('Vantaris acceso: $e');
    return [];
  }
}

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
  final antes = _pendientes[clave];
  List<String> cola;
  if (antes != null && DateTime.now().difference(antes.$2) < const Duration(seconds: 30)) {
    cola = antes.$1; // la anterior no valió: la siguiente
  } else {
    final api = await bind.mainGetApiServer();
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (api.isEmpty || token.isEmpty) return false;
    cola = await _pedirClaves(api, token, peerId);
  }
  if (cola.isEmpty) {
    _pendientes.remove(clave);
    return false;
  }
  final pwd = cola.first;
  _pendientes[clave] = (cola.sublist(1), DateTime.now());
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
        .post(Uri.parse('$api/api/login'),
            // Sin esta cabecera el servidor Pro contesta 415 en texto plano y el alta fallaba
            // siempre con «Sin conexión» (1.5.0).
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(req.toJson()))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401 || r.statusCode == 403) {
      return (null, 'Usuario o contraseña de técnico incorrectos.');
    }
    final Map body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    } catch (_) {
      return (null, 'El servidor de soporte ha respondido algo inesperado (${r.statusCode}).');
    }
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
