// Vantaris: cada técnico entra en «Vantaris Técnico» con SU cuenta del RustDesk Server Pro.
//
// Para qué: el registro de auditoría de Pro (Logs › Connection) apunta el usuario que controla,
// el equipo, la IP y la duración. Además librustdesk manda el nombre visible de la cuenta en el
// LoginRequest (my_name), así que la píldora «Técnico Vantaris conectado · <nombre>» del equipo
// controlado ya sale con el nombre del técnico sin tocar el protocolo.
//
// Qué hace este fichero (solo en la variante Técnico):
//   - Al abrir, si no hay sesión, pide el login de Pro (el diálogo propio de RustDesk).
//   - Antes de abrir cualquier conexión (botón, historial, enlace rustdesk:// de Falcon o
//     --connect), si no hay sesión la pide; sin sesión no se conecta.
//   - Tarjeta en la pantalla principal con el técnico conectado y «Cerrar sesión».
//   - Registra los enlaces rustdesk:// (y vantaristecnico://) para el usuario de Windows, así el
//     botón «Conectar» de los tickets de Falcon abre este Técnico aunque no se haya instalado.
//
// Cuándo se exige: en la variante Técnico con la config firmada de Pro (hay servidor de cuentas).
// Se puede apagar desde la consola con «vantaris-exigir-login=N» en los override settings, y
// forzar para pruebas con la variable de entorno VANTARIS_EXIGIR_LOGIN=1.
// La variante se sabe por --dart-define=VANTARIS_VARIANT (build-vantaris.sh), por la config de
// Pro (conn-type saliente) o por la variable VANTARIS_VARIANT.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../common/widgets/login.dart';
import '../models/platform_model.dart';

const _kTeal = Color(0xFF03B5A5);

bool get vantarisEsTecnico {
  if (!isDesktop) return false;
  const v = String.fromEnvironment('VANTARIS_VARIANT');
  if (v.isNotEmpty) return v == 'tecnico';
  return bind.isOutgoingOnly() || Platform.environment['VANTARIS_VARIANT'] == 'tecnico';
}

bool get vantarisExigeLogin {
  if (!vantarisEsTecnico || bind.isDisableAccount()) return false;
  if (Platform.environment['VANTARIS_EXIGIR_LOGIN'] == '1') return true;
  if (bind.mainGetBuildinOption(key: 'vantaris-exigir-login') == 'N') return false;
  return bind.isCustomClient();
}

bool _pidiendo = false;

/// Pide el login si hace falta. true = se puede conectar.
Future<bool> vantarisTecnicoPuedeConectar() async {
  if (!vantarisExigeLogin || gFFI.userModel.isLogin) return true;
  if (_pidiendo) return false;
  _pidiendo = true;
  _log('conexión parada: sin sesión de técnico, se pide el login');
  try {
    // Con --connect o un enlace la ventana principal está oculta: sacarla para que se vea el login.
    await windowOnTop(null);
    showToast('Entra con tu cuenta de técnico para conectar.',
        timeout: const Duration(seconds: 4));
    await loginDialog();
  } finally {
    _pidiendo = false;
  }
  _log('login cerrado: ${gFFI.userModel.isLogin ? 'con sesión, se conecta' : 'sin sesión, no se conecta'}');
  return gFFI.userModel.isLogin;
}

/// Solo en pruebas (VANTARIS_EXIGIR_LOGIN=1): %TEMP%\vantaris-login.log.
void _log(String m) {
  if (Platform.environment['VANTARIS_EXIGIR_LOGIN'] != '1') return;
  try {
    File('${Directory.systemTemp.path}${Platform.pathSeparator}vantaris-login.log')
        .writeAsStringSync('${DateTime.now().toIso8601String()} $m\n', mode: FileMode.append);
  } catch (_) {}
}

/// Esquemas de enlace que abre el Técnico: el de Falcon y el propio de la app.
const vantarisEsquemasTecnico = ['rustdesk', 'vantaristecnico'];

/// Registra los esquemas en HKCU\Software\Classes (sin permisos de administrador) apuntando a este
/// .exe. Si ya apuntan aquí no toca nada. Windows mira HKCU antes que el HKCR que deja la
/// instalación oficial de RustDesk, así que el Técnico gana aunque esté el RustDesk normal.
Future<void> vantarisRegistrarEnlaces() async {
  if (!isWindows || !vantarisEsTecnico) return;
  final exe = Platform.resolvedExecutable;
  final orden = '"$exe" "%1"';
  for (final esquema in vantarisEsquemasTecnico) {
    final clave = 'HKCU\\Software\\Classes\\$esquema';
    try {
      // reg.exe escribe en la página de códigos OEM (las tildes de «Técnico» no casan al leerlo):
      // se compara con la ruta que se registró la última vez, guardada en una opción local.
      final q = await Process.run('reg', ['query', '$clave\\shell\\open\\command', '/ve']);
      if (q.exitCode == 0 && bind.mainGetLocalOption(key: 'vantaris-enlace-$esquema') == exe) {
        continue;
      }
      for (final args in [
        ['add', clave, '/ve', '/d', 'URL:Vantaris Técnico', '/f'],
        ['add', clave, '/v', 'URL Protocol', '/d', '', '/f'],
        ['add', '$clave\\DefaultIcon', '/ve', '/d', '"$exe",0', '/f'],
        ['add', '$clave\\shell\\open\\command', '/ve', '/d', orden, '/f'],
      ]) {
        await Process.run('reg', args);
      }
      await bind.mainSetLocalOption(key: 'vantaris-enlace-$esquema', value: exe);
      _log('enlaces $esquema:// registrados en $exe');
    } catch (e) {
      _log('no se pudo registrar $esquema://: $e');
    }
  }
}

/// Tarjeta de la pantalla principal: quién está conectado.
class VantarisTecnicoCard extends StatefulWidget {
  const VantarisTecnicoCard({Key? key}) : super(key: key);

  @override
  State<VantarisTecnicoCard> createState() => _VantarisTecnicoCardState();
}

class _VantarisTecnicoCardState extends State<VantarisTecnicoCard> {
  @override
  void initState() {
    super.initState();
    vantarisRegistrarEnlaces();
    // Al abrir la app: si hace falta cuenta y no hay sesión, se pide ya.
    if (vantarisExigeLogin) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && !gFFI.userModel.isLogin) vantarisTecnicoPuedeConectar();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!vantarisEsTecnico) return const SizedBox.shrink();
    return Obx(() {
      final dentro = gFFI.userModel.isLogin;
      final nombre = gFFI.userModel.displayNameOrUserName;
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: dentro ? _kTeal : Colors.orange, width: 1.2),
        ),
        child: Row(children: [
          Icon(dentro ? Icons.badge : Icons.person_off,
              color: dentro ? _kTeal : Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(dentro ? nombre : 'Sin iniciar sesión',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              Text(
                  dentro
                      ? 'Técnico conectado'
                      : (vantarisExigeLogin ? 'Hace falta para conectar' : 'Opcional'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
          TextButton(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 30)),
            onPressed: () => dentro ? gFFI.userModel.logOut() : loginDialog(),
            child: Text(dentro ? 'Salir' : 'Entrar', style: const TextStyle(fontSize: 12)),
          ),
        ]),
      );
    });
  }
}
