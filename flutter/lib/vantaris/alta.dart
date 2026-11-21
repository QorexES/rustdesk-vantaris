// Vantaris: «alta del equipo» para el acceso desatendido (Android, variante Soporte).
//
// Sin alta, RustDesk pide que alguien pulse «Aceptar» en la tablet cada vez que entra un técnico.
// Con alta, el técnico entra con la CONTRASEÑA PERMANENTE DE ESE EQUIPO (una por equipo, la calcula el
// servidor a partir del ID y nadie la ve ni la apunta; nunca va en el binario) y nadie tiene que tocar
// nada. El técnico con sesión la pide al servidor al conectar (acceso.dart). El cliente sigue sabiendo
// siempre que hay alguien: la píldora «Técnico Vantaris conectado» (guard.dart) no depende de esto.
//
// Qué deja fijado el alta:
//   - contraseña permanente (Config::set_permanent_password, cifrada por librustdesk);
//   - approve-mode=password + verification-method=use-permanent-password (sin «Aceptar»,
//     sin contraseña de un solo uso);
//   - «Iniciar al arrancar» (BootReceiver) y el aviso «Podrías estar siendo ESTAFADO» apagado
//     (lo instala Vantaris, no un desconocido por teléfono).
// Lo que NO puede hacer la app sola (lo hace scripts/provisionar-android.ps1 por cable): el permiso
// de captura sin diálogo (appops PROJECT_MEDIA), la accesibilidad y la lista blanca de batería.
//
// Tres caminos:
//   - AUTOMÁTICO (1.5.2): al abrir la app sin alta, el equipo pide SU contraseña al servidor firmando
//     con su clave privada de RustDesk (la de RustDesk.toml, la misma con la que se registra en hbbs).
//     El servidor la comprueba con la clave pública que tiene hbbs para ese ID, así que solo la consigue
//     el propio equipo. Ver vantarisAltaAutomatica y deploy/pro/turn-credenciales.
//   - la tarjeta de esta pantalla, con la cuenta del técnico;
//   - el script por adb, que deja la contraseña pendiente (VantarisAlta.kt) y aquí se aplica al abrir
//     la app. Por adb también se puede dar de baja (y la baja apaga el alta automática).
//
// OJO con la config de Pro: si el override lleva «disable-change-permanent-password=Y», librustdesk
// rechaza cualquier contraseña nueva (también la de aquí). Ver client-build/pro-generador.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';
import '../models/server_model.dart';
import 'acceso.dart';
import 'play.dart';
import 'update/ed25519.dart';

// Mismo canal que usa native_model.dart; gFFI.invokeMethod espera un bool y aquí vuelve JSON.
const _mChannel = MethodChannel('mChannel');

Future<String> _canal(String args) async =>
    await _mChannel.invokeMethod<String>('vantaris_alta', args) ?? '{}';

const _kTeal = Color(0xFF03B5A5);
const _kAmbar = Color(0xFFE08A00);

/// ¿Hay que mostrar el alta? Solo en el Android que se deja controlar.
bool get vantarisAltaAplica => isAndroid && !bind.isOutgoingOnly();

/// ¿Está el equipo listo para entrar sin «Aceptar»?
Future<bool> vantarisAltaHecha() async {
  final approve = await bind.mainGetOption(key: kOptionApproveMode);
  final method = await bind.mainGetOption(key: kOptionVerificationMethod);
  final pwd = await bind.mainGetCommon(key: 'permanent-password-set');
  return approve == 'password' && method == kUsePermanentPassword && pwd == 'true';
}

/// Contraseña aleatoria de 12 caracteres sin letras que se confundan (0/O, 1/l/I).
String vantarisGenerarPassword() {
  const letras = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(12, (_) => letras[r.nextInt(letras.length)]).join();
}

/// Sube cada vez que cambia el alta (aplicada o quitada): la tarjeta la escucha para refrescarse
/// enseguida, también cuando el alta llega sola (automática o por cable) con la pantalla abierta.
final vantarisAltaCambio = ValueNotifier<int>(0);

bool _valida(String p) => RegExp(r'^[\x21-\x7E]{8,64}$').hasMatch(p);

/// Aplica el alta. Devuelve null si ha ido bien o el motivo del fallo.
Future<String?> vantarisAplicarAlta(String pwd, {bool arranque = true}) async {
  if (!_valida(pwd)) return 'La contraseña debe tener entre 8 y 64 caracteres, sin espacios.';
  final ok = await bind.mainSetPermanentPasswordWithResult(password: pwd);
  if (!ok) {
    return 'El programa no deja cambiar la contraseña (está bloqueado en la configuración del '
        'servidor: quitar «disable-change-permanent-password»).';
  }
  await bind.mainSetOption(key: kOptionApproveMode, value: 'password');
  await bind.mainSetOption(key: kOptionVerificationMethod, value: kUsePermanentPassword);
  await bind.mainSetLocalOption(key: 'show-scam-warning', value: 'N');
  await _canal(jsonEncode({'op': 'hecha', 'arranque': arranque}));
  await gFFI.serverModel.updatePasswordModel();
  vantarisAltaCambio.value++;
  return null;
}

/// Baja (equipo retirado o pruebas): vuelve a lo de RustDesk por defecto, con «Aceptar».
Future<void> vantarisQuitarAlta() async {
  await bind.mainSetPermanentPasswordWithResult(password: '');
  await bind.mainSetOption(key: kOptionApproveMode, value: '');
  await bind.mainSetOption(key: kOptionVerificationMethod, value: '');
  await bind.mainSetLocalOption(key: 'show-scam-warning', value: '');
  // Dado de baja a propósito: que el alta automática no lo vuelva a dar de alta.
  await bind.mainSetLocalOption(key: _kAltaAuto, value: 'N');
  await _canal(jsonEncode({'op': 'baja-hecha'}));
  await gFFI.serverModel.updatePasswordModel();
  vantarisAltaCambio.value++;
}

/// Si el script por cable ha dejado una contraseña, se aplica ahora (y se borra).
Future<void> vantarisAltaPendiente() async {
  if (!vantarisAltaAplica) return;
  try {
    // El ID, para que provisionar-android.ps1 pida al servidor la contraseña de este equipo.
    final id = await bind.mainGetMyId();
    if (id.isNotEmpty) await _canal(jsonEncode({'op': 'id', 'id': id}));
    final res = await _canal(jsonEncode({'op': 'pendiente'}));
    final m = jsonDecode(res) as Map;
    if (m['baja'] == true) {
      await vantarisQuitarAlta();
      showToast('Alta del equipo quitada: vuelve a pedir «Aceptar».');
      return;
    }
    final pwd = m['password'] as String? ?? '';
    if (pwd.isEmpty) {
      unawaited(vantarisAltaAutomatica());
      return;
    }
    final err = await vantarisAplicarAlta(pwd);
    if (err != null) {
      showToast('Alta del equipo: $err', timeout: const Duration(seconds: 8));
      return;
    }
    if (!gFFI.serverModel.isStart) await gFFI.serverModel.startService();
    showToast('Equipo dado de alta para el soporte a distancia.');
  } catch (e) {
    debugPrint('vantaris alta pendiente: $e');
  }
}

const _kAltaAuto = 'vantaris-alta-automatica';
bool _altaAutoEnCurso = false;

/// Semilla Ed25519 (32 bytes) y clave pública del equipo, leídas del RustDesk.toml de la app
/// (`key_pair = [[64 bytes de libsodium: semilla + pública], [32 bytes de la pública]]`).
Future<(List<int>, List<int>)?> _claveDelEquipo() async {
  final dir = Directory((await getApplicationDocumentsDirectory()).path);
  final patron = RegExp(r'key_pair\s*=\s*\[\s*\[([\d,\s]+)\]\s*,\s*\[([\d,\s]+)\]');
  List<int> bytes(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).map(int.parse).toList();
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.toml')) continue;
    final m = patron.firstMatch(await f.readAsString());
    if (m == null) continue;
    final sk = bytes(m.group(1)!), pk = bytes(m.group(2)!);
    if (sk.length != 64 || pk.length != 32) continue;
    final semilla = sk.sublist(0, 32);
    // Comprobación local: si la semilla no da esa pública, no se manda nada.
    if (ed25519PublicKey(semilla).toString() != pk.toString()) continue;
    return (semilla, pk);
  }
  return null;
}

/// Una petición de alta automática. Devuelve la contraseña, o null y si merece la pena reintentar.
Future<(String?, bool)> _pedirAltaAutomatica(String api) async {
  final id = (await bind.mainGetMyId()).replaceAll(' ', '');
  if (id.isEmpty) return (null, true);
  final clave = await _claveDelEquipo();
  if (clave == null) {
    // Recién instalado: RustDesk genera la clave y la guarda un instante después.
    debugPrint('Vantaris alta automática: aún no encuentro la clave del equipo');
    return (null, true);
  }
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final firma = ed25519Sign(clave.$1, utf8.encode('vantaris-alta:v1:$id:$ts'));
  try {
    final r = await http
        .post(Uri.parse('$api/acceso/registro'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id': id, 'ts': ts, 'firma': base64.encode(firma)}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) {
      final p = (jsonDecode(r.body) as Map)['password'];
      return (p is String && p.isNotEmpty ? p : null, false);
    }
    debugPrint('Vantaris alta automática: el servidor contesta ${r.statusCode}');
    // 404: hbbs aún no conoce este ID (recién instalado). 403: también se reintenta: la primera vez
    // que arranca, RustDesk genera la clave y el ID y los guarda un instante después, y la clave
    // leída del fichero puede no ser aún la que tiene el servidor. 429/5xx: más tarde. 400: no.
    return (null, r.statusCode == 404 || r.statusCode == 403 || r.statusCode == 429 || r.statusCode >= 500);
  } catch (e) {
    debugPrint('Vantaris alta automática: $e');
    return (null, true);
  }
}

/// Alta automática, una vez por ID: pide la contraseña del equipo al servidor sin técnico y la deja
/// puesta. También en equipos YA dados de alta: los instalados con versiones viejas tienen una
/// contraseña genérica o a mano que el servidor no conoce, y así pasan solos a la suya (regularizar
/// la flota). Solo se respeta una baja hecha a propósito («N»). Reintenta un rato (el ID tarda en
/// aparecer en hbbs tras instalar, o no hay red al arrancar).
Future<void> vantarisAltaAutomatica() async {
  if (!vantarisAltaAplica || _altaAutoEnCurso) return;
  if (bind.mainGetLocalOption(key: _kAltaAuto) == 'N') return; // baja a propósito
  _altaAutoEnCurso = true;
  try {
    final api = await bind.mainGetApiServer();
    if (api.isEmpty) return;
    for (var intento = 0; intento < 40; intento++) {
      final id = (await bind.mainGetMyId()).replaceAll(' ', '');
      // El ID para otras apps (el TPV lo enseña como código de soporte), aunque nunca se abra la app.
      if (id.isNotEmpty) {
        try {
          await _canal(jsonEncode({'op': 'id', 'id': id}));
        } catch (_) {}
      }
      if (id.isNotEmpty && bind.mainGetLocalOption(key: _kAltaAuto) == 'v1:$id') return; // ya hecha
      final teniaAlta = await vantarisAltaHecha();
      final (pwd, reintentar) = await _pedirAltaAutomatica(api);
      if (pwd != null) {
        final err = await vantarisAplicarAlta(pwd);
        if (err != null) {
          showToast('Alta automática: $err', timeout: const Duration(seconds: 8));
        } else {
          await bind.mainSetLocalOption(key: _kAltaAuto, value: 'v1:$id');
          if (!teniaAlta) showToast('Equipo dado de alta para el soporte a distancia de Vantaris.');
        }
        return;
      }
      if (!reintentar) return;
      // 30 s los primeros minutos, luego cada 2 min (unos 70 min en total).
      await Future.delayed(Duration(seconds: intento < 10 ? 30 : 120));
    }
  } finally {
    _altaAutoEnCurso = false;
  }
}

/// Un intento de alta automática ahora mismo (botón «Dar de alta»): null si ha ido bien o el motivo.
Future<String?> vantarisAltaAutomaticaYa() async {
  final api = await bind.mainGetApiServer();
  if (api.isEmpty) return 'Este programa no tiene servidor configurado.';
  final (pwd, reintentar) = await _pedirAltaAutomatica(api);
  if (pwd == null) {
    return reintentar
        ? 'El servidor aún no conoce este equipo: inicia el servicio y vuelve a probar en un minuto.'
        : 'El servidor no ha aceptado el alta automática.';
  }
  final err = await vantarisAplicarAlta(pwd);
  if (err == null) {
    final id = (await bind.mainGetMyId()).replaceAll(' ', '');
    await bind.mainSetLocalOption(key: _kAltaAuto, value: 'v1:$id');
  }
  return err;
}

/// Tarjeta de arriba en «Compartir pantalla».
class VantarisAltaCard extends StatefulWidget {
  const VantarisAltaCard({Key? key}) : super(key: key);

  @override
  State<VantarisAltaCard> createState() => _VantarisAltaCardState();
}

class _VantarisAltaCardState extends State<VantarisAltaCard> {
  bool? _hecha;

  @override
  void initState() {
    super.initState();
    _refresh();
    // La tarjeta no escucha los cambios de config: se refresca con el modelo.
    gFFI.serverModel.addListener(_refresh);
    vantarisAltaCambio.addListener(_refresh);
  }

  @override
  void dispose() {
    gFFI.serverModel.removeListener(_refresh);
    vantarisAltaCambio.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final h = await vantarisAltaHecha();
    if (mounted && h != _hecha) setState(() => _hecha = h);
  }

  @override
  Widget build(BuildContext context) {
    if (!vantarisAltaAplica || _hecha == null) return const SizedBox.shrink();
    final hecha = _hecha!;
    final color = hecha ? _kTeal : _kAmbar;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: BorderSide(color: color, width: 1.5)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // Ya dada de alta: cambiar la contraseña solo con pulsación larga (para el instalador).
        onLongPress: hecha ? () => _abrirAlta(cambiar: true) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(hecha ? Icons.verified_user : Icons.front_hand, color: color, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(hecha ? 'Soporte a distancia listo' : 'Soporte a distancia sin dar de alta',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  hecha
                      ? 'Los técnicos de Vantaris pueden entrar sin que tengas que aceptar. '
                          'Mientras haya uno conectado lo verás arriba y podrás colgar.'
                      : 'Ahora alguien tiene que pulsar «Aceptar» en esta pantalla cada vez que '
                          'entra un técnico. El instalador de Vantaris puede dejarlo listo.',
                  style: const TextStyle(fontSize: 13),
                ),
              ]),
            ),
            if (!hecha)
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _kAmbar),
                // Sin usuario ni contraseña: primero el alta automática; si no se puede, el
                // formulario del técnico.
                onPressed: () async {
                  final err = await vantarisAltaAutomaticaYa();
                  if (err == null) {
                    showToast('Equipo dado de alta para el soporte a distancia de Vantaris.');
                  } else {
                    showToast(err, timeout: const Duration(seconds: 6));
                    if (mounted) await _abrirAlta(cambiar: false);
                  }
                },
                child: const Text('Dar de alta'),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _abrirAlta({required bool cambiar}) async {
    final usuario = TextEditingController();
    final clave = TextEditingController();
    var arranque = true;
    String? error;
    var ocupado = false;
    final id = gFFI.serverModel.serverId.text;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        Future<void> enviar() async {
          if (usuario.text.trim().isEmpty || clave.text.isEmpty) {
            setState(() => error = 'Escribe tu usuario y tu contraseña de técnico.');
            return;
          }
          setState(() {
            ocupado = true;
            error = null;
          });
          // La contraseña del equipo la da el servidor (es solo de este equipo y nadie la ve):
          // los técnicos con sesión entran sin escribirla. Ver acceso.dart.
          final (pwd, fallo) = await vantarisClaveParaAlta(usuario.text.trim(), clave.text);
          final err = fallo ?? await _alta(pwd!, arranque);
          if (err != null) {
            setState(() {
              error = err;
              ocupado = false;
            });
          } else if (context.mounted) {
            Navigator.pop(context, true);
          }
        }

        return AlertDialog(
          title: Text(cambiar ? 'Volver a dar de alta el equipo' : 'Alta del equipo (instalador)'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Entra con tu cuenta de técnico de Vantaris. El equipo queda con una '
                  'contraseña propia que nadie tiene que apuntar: los técnicos con sesión entran '
                  'sin escribirla y sin que nadie tenga que aceptar.'),
              const SizedBox(height: 12),
              Text('ID del equipo: $id', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: usuario,
                enabled: !ocupado,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Usuario de técnico'),
              ),
              TextField(
                controller: clave,
                enabled: !ocupado,
                obscureText: true,
                decoration: InputDecoration(labelText: 'Contraseña de técnico', errorText: error),
                onSubmitted: (_) => ocupado ? null : enviar(),
              ),
              const SizedBox(height: 4),
              const Text('Tu sesión solo se usa un momento para el alta y se cierra al terminar.',
                  style: TextStyle(fontSize: 12)),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: arranque,
                onChanged: ocupado ? null : (v) => setState(() => arranque = v ?? true),
                title: const Text('Arrancar solo al encender el equipo'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: ocupado ? null : () => Navigator.pop(context, false), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: ocupado ? null : enviar,
              child: ocupado
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(cambiar ? 'Volver a dar de alta' : 'Dar de alta'),
            ),
          ],
        );
      }),
    );
    if (ok == true) {
      showToast('Listo: los técnicos ya pueden entrar sin «Aceptar».',
          timeout: const Duration(seconds: 5));
      _refresh();
    }
  }

  Future<String?> _alta(String pwd, bool arranque) async {
    if (arranque) {
      // BootReceiver solo arranca si tiene ventana flotante y está fuera del ahorro de batería.
      if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
        await AndroidPermissionManager.request(kSystemAlertWindow);
      }
      if (!await AndroidPermissionManager.check(kRequestIgnoreBatteryOptimizations)) {
        await AndroidPermissionManager.request(kRequestIgnoreBatteryOptimizations);
      }
    }
    final err = await vantarisAplicarAlta(pwd, arranque: arranque);
    if (err == null && !gFFI.serverModel.isStart) {
      // Vantaris Play: aviso breve antes de pedir la captura (si dice que no, el alta queda hecha
      // y la captura se puede iniciar luego con «Iniciar servicio»).
      if (!kVantarisPlay || await vantarisAvisoCaptura(gFFI.dialogManager)) {
        await gFFI.serverModel.startService();
      }
    }
    return err;
  }
}
