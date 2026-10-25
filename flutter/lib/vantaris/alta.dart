// Vantaris: «alta del equipo» para el acceso desatendido (Android, variante Soporte).
//
// Sin alta, RustDesk pide que alguien pulse «Aceptar» en la tablet cada vez que entra un técnico.
// Con alta, el técnico entra con la CONTRASEÑA PERMANENTE DE ESE EQUIPO (una por equipo, la pone
// el instalador; nunca va en el binario) y nadie tiene que tocar nada. El cliente sigue sabiendo
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
// Dos caminos: la tarjeta de esta pantalla, o el script por adb, que deja la contraseña pendiente
// (VantarisAlta.kt) y aquí se aplica al abrir la app. Por adb también se puede dar de baja.
//
// OJO con la config de Pro: si el override lleva «disable-change-permanent-password=Y», librustdesk
// rechaza cualquier contraseña nueva (también la de aquí). Ver client-build/pro-generador.md.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';
import '../models/server_model.dart';
import 'play.dart';

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
  return null;
}

/// Baja (equipo retirado o pruebas): vuelve a lo de RustDesk por defecto, con «Aceptar».
Future<void> vantarisQuitarAlta() async {
  await bind.mainSetPermanentPasswordWithResult(password: '');
  await bind.mainSetOption(key: kOptionApproveMode, value: '');
  await bind.mainSetOption(key: kOptionVerificationMethod, value: '');
  await bind.mainSetLocalOption(key: 'show-scam-warning', value: '');
  await _canal(jsonEncode({'op': 'baja-hecha'}));
  await gFFI.serverModel.updatePasswordModel();
}

/// Si el script por cable ha dejado una contraseña, se aplica ahora (y se borra).
Future<void> vantarisAltaPendiente() async {
  if (!vantarisAltaAplica) return;
  try {
    final res = await _canal(jsonEncode({'op': 'pendiente'}));
    final m = jsonDecode(res) as Map;
    if (m['baja'] == true) {
      await vantarisQuitarAlta();
      showToast('Alta del equipo quitada: vuelve a pedir «Aceptar».');
      return;
    }
    final pwd = m['password'] as String? ?? '';
    if (pwd.isEmpty) return;
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
  }

  @override
  void dispose() {
    gFFI.serverModel.removeListener(_refresh);
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
                onPressed: () => _abrirAlta(cambiar: false),
                child: const Text('Dar de alta'),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _abrirAlta({required bool cambiar}) async {
    final ctrl = TextEditingController(text: vantarisGenerarPassword());
    var arranque = true;
    String? error;
    var ocupado = false;
    final id = gFFI.serverModel.serverId.text;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          title: Text(cambiar ? 'Cambiar la contraseña del equipo' : 'Alta del equipo (instalador)'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Con esta contraseña los técnicos entrarán sin que nadie tenga que '
                  'aceptar. Es solo de este equipo.'),
              const SizedBox(height: 12),
              Text('ID del equipo: $id', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
                decoration: InputDecoration(
                  labelText: 'Contraseña del equipo',
                  errorText: error,
                  suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Generar otra',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => setState(() => ctrl.text = vantarisGenerarPassword()),
                    ),
                    IconButton(
                      tooltip: 'Copiar',
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: 'ID $id  ·  contraseña ${ctrl.text}'));
                        showToast('Copiado');
                      },
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Apúntala en la ficha del local (Falcon / libreta del servidor) ANTES de '
                  'continuar: después no se puede volver a ver.',
                  style: TextStyle(fontSize: 12, color: _kAmbar)),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: arranque,
                onChanged: (v) => setState(() => arranque = v ?? true),
                title: const Text('Arrancar solo al encender el equipo'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: ocupado ? null : () => Navigator.pop(context, false), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: ocupado
                  ? null
                  : () async {
                      setState(() => ocupado = true);
                      final err = await _alta(ctrl.text.trim(), arranque);
                      if (err != null) {
                        setState(() {
                          error = err;
                          ocupado = false;
                        });
                      } else if (context.mounted) {
                        Navigator.pop(context, true);
                      }
                    },
              child: Text(cambiar ? 'Cambiar' : 'Dar de alta'),
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
