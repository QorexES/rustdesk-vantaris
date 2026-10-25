// Vantaris: actualizaciones propias de los clientes (sustituyen al aviso del RustDesk oficial).
//
// RustDesk 1.4.9 pregunta a api.rustdesk.com si hay versión nueva (mandando la huella del equipo) y
// ofrece bajar el RustDesk genérico de GitHub, que quitaría la marca y todo lo nuestro. Aquí:
//   - checkUpdate() (common.dart) llama a vantarisUpdateStart() y ya no hace esa consulta nunca.
//   - Se ocultan las casillas «Buscar actualizaciones al iniciar» y «Actualización automática»
//     (esta última activaría el actualizador en Rust, que baja rustdesk-<v>.exe de GitHub), y si
//     alguien la tenía puesta se vuelve a apagar.
//   - Se consulta NUESTRO manifiesto firmado (manifest.dart):
//       <base>/<canal>/<plataforma>-<variante>.json, base = https://soporte.vantaris.es/actualizaciones
//     Nada se instala si la firma, la variante, el canal o el hash del paquete no cuadran.
//
// Por plataforma:
//   - Técnico Windows: pregunta («Actualizar ahora» / «Más tarde») y avisa si hay conexiones abiertas.
//   - Soporte Windows: NO se hace aquí. Lo hace el runner en C++ desde el servicio (SYSTEM), sin
//     preguntar y solo sin asistencia en curso (windows/runner/vantaris_update.cpp). Desde Dart solo
//     se marca «hay asistencia» (vantarisSessionHeartbeat, en el proceso --cm).
//   - Soporte Android: aviso discreto en la pantalla principal; al tocar «Actualizar», descarga,
//     comprueba y abre el instalador del sistema (el usuario confirma). Nunca con técnico conectado.
//
// Para pruebas: VANTARIS_UPDATE_URL=<base> (o la opción local «vantaris-update-url»),
// VANTARIS_UPDATE_CHECK_NOW=1 comprueba a los 3 s. Registro en %TEMP%\vantaris-actualizar.log.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/multi_window_manager.dart';
import 'manifest.dart';
import '../play.dart';

const kVantarisBuild = int.fromEnvironment('VANTARIS_BUILD');
const kVantarisVariante = String.fromEnvironment('VANTARIS_VARIANTE');
const _kCanal = String.fromEnvironment('VANTARIS_UPDATE_CANAL', defaultValue: 'estable');
const _kKeys = String.fromEnvironment('VANTARIS_UPDATE_KEYS');
const _kBase = String.fromEnvironment('VANTARIS_UPDATE_BASE',
    defaultValue: 'https://soporte.vantaris.es/actualizaciones');

const _kFirstDelayDesktop = Duration(seconds: 20);
const _kFirstDelayAndroid = Duration(seconds: 60);
const _kEvery = Duration(hours: 6);

/// Hay versión nueva lista para ofrecer (Android: la muestra VantarisUpdateBanner).
final vantarisUpdateAvailable = Rxn<VantarisManifest>();
final vantarisUpdateBusy = false.obs;
final vantarisUpdateProgress = 0.0.obs;
final vantarisUpdateError = ''.obs;

Timer? _timer;
bool _asking = false;
final Set<int> _postponed = {};

void _log(String s) {
  debugPrint('[vantaris-actualizar] $s');
  if (!isWindows) return;
  try {
    File('${Directory.systemTemp.path}\\vantaris-actualizar.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $s\n',
        mode: FileMode.append,
        flush: true);
  } catch (_) {}
}

String get _plataforma => isAndroid ? 'android' : 'windows';

String _canal() {
  final o = bind.mainGetLocalOption(key: 'vantaris-update-canal');
  return (o == 'estable' || o == 'pruebas') ? o : _kCanal;
}

String _base() {
  final env = isWindows ? Platform.environment['VANTARIS_UPDATE_URL'] : null;
  if (env != null && env.isNotEmpty) return env;
  final o = bind.mainGetLocalOption(key: 'vantaris-update-url');
  return o.isNotEmpty ? o : _kBase;
}

Uri vantarisManifestUrl() {
  var b = _base();
  if (b.endsWith('/')) b = b.substring(0, b.length - 1);
  return Uri.parse('$b/${_canal()}/$_plataforma-$kVantarisVariante.json');
}

/// Sustituye a la comprobación de RustDesk. Siempre devuelve true (no se hace la oficial).
bool vantarisUpdateStart() {
  if (isWeb) return true;
  if (isWindows) {
    // La casilla está oculta, pero si alguien la dejó puesta el Rust bajaría RustDesk de GitHub.
    bind.mainGetOption(key: 'allow-auto-update').then((v) {
      if (v == 'Y') bind.mainSetOption(key: 'allow-auto-update', value: 'N');
    });
  }
  if (kVantarisPlay) {
    _log('versión de Google Play: las actualizaciones las da la tienda');
    return true;
  }
  if (kVantarisBuild <= 0 || kVantarisVariante.isEmpty) {
    _log('compilación sin datos de versión: actualizaciones desactivadas');
    return true;
  }
  final desktopTecnico = isWindows && kVantarisVariante == 'tecnico';
  final androidSoporte = isAndroid && kVantarisVariante == 'soporte';
  if (!desktopTecnico && !androidSoporte) return true; // Soporte Windows: lo hace el runner (C++)
  final now = isWindows && Platform.environment['VANTARIS_UPDATE_CHECK_NOW'] == '1';
  final first = now
      ? const Duration(seconds: 3)
      : (isAndroid ? _kFirstDelayAndroid : _kFirstDelayDesktop);
  _timer?.cancel();
  Timer(first, () {
    vantarisCheckNow();
    _timer = Timer.periodic(_kEvery, (_) => vantarisCheckNow());
  });
  return true;
}

/// Consulta el manifiesto; si hay versión mayor y válida, la ofrece. Devuelve el manifiesto o null.
Future<VantarisManifest?> vantarisCheckNow() async {
  final url = vantarisManifestUrl();
  try {
    final keys = vantarisParseKeys(_kKeys);
    if (keys.isEmpty) {
      _log('sin claves públicas en el cliente: no se acepta nada');
      return null;
    }
    final resp = await http.get(url).timeout(const Duration(seconds: 20));
    if (resp.statusCode == 404) {
      _log('sin manifiesto en $url');
      return null;
    }
    if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
    if (resp.bodyBytes.length > 65536) throw 'manifiesto demasiado grande';
    final m = vantarisVerifyManifest(utf8.decode(resp.bodyBytes),
        manifestUrl: url,
        keys: keys,
        variante: kVantarisVariante,
        plataforma: _plataforma,
        canal: _canal());
    if (m.build <= kVantarisBuild) {
      _log('al día (instalada $kVantarisBuild, publicada ${m.build})');
      vantarisUpdateAvailable.value = null;
      return null;
    }
    if (_pick(m) == null) {
      _log('la versión ${m.build} no trae paquete para este equipo');
      return null;
    }
    _log('VERSIÓN NUEVA ${m.version} build ${m.build} (instalada $kVantarisBuild), firma OK');
    vantarisUpdateAvailable.value = m;
    if (isWindows) _askTecnico(m);
    return m;
  } on VantarisManifestError catch (e) {
    _log('MANIFIESTO RECHAZADO ($url): $e');
  } catch (e) {
    _log('no se pudo comprobar $url: $e');
  }
  return null;
}

VantarisPackage? _pick(VantarisManifest m) {
  if (isWindows) return m.paquetes['x64'];
  final arm64 = Platform.version.contains('arm64');
  return m.paquetes[arm64 ? 'arm64' : 'arm32'];
}

/// Descarga el paquete comprobando tamaño y SHA-256 por el camino. Devuelve el fichero o lanza.
Future<File> _download(VantarisPackage p, String name) async {
  final dir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}vantaris-actualizacion');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final f = File('${dir.path}${Platform.pathSeparator}$name');
  final client = http.Client();
  try {
    final resp = await client.send(http.Request('GET', p.url));
    if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode} al bajar el paquete';
    final sink = f.openWrite();
    final digestOut = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(digestOut);
    var got = 0;
    await for (final chunk in resp.stream) {
      got += chunk.length;
      if (got > p.size) {
        await sink.close();
        throw 'el paquete es más grande de lo anunciado';
      }
      hasher.add(chunk);
      sink.add(chunk);
      vantarisUpdateProgress.value = got / p.size;
    }
    hasher.close();
    await sink.close();
    if (got != p.size) throw 'tamaño distinto del anunciado ($got ≠ ${p.size})';
    final hex = digestOut.value.toString();
    if (hex != p.sha256) {
      await f.delete();
      throw 'EL HASH NO CUADRA: no se instala';
    }
    _log('paquete descargado y comprobado (sha256 $hex)');
    return f;
  } finally {
    client.close();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

// ---------------------------------------------------------------- Técnico (Windows)

Future<void> _askTecnico(VantarisManifest m) async {
  if (_asking || _postponed.contains(m.build)) return;
  _asking = true;
  final open = (await rustDeskWinManager.getAllSubWindowIds()).isNotEmpty;
  final ok = await gFFI.dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      title: const Text('Hay una versión nueva de Vantaris Técnico'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Versión ${m.version} (compilación ${m.build}). '
              'Tienes la $kVantarisBuild.'),
          if (m.notas.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(m.notas),
          ],
          if (open) ...[
            const SizedBox(height: 8),
            const Text('Se cerrarán las conexiones que tienes abiertas.',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
          const SizedBox(height: 8),
          Obx(() => vantarisUpdateBusy.isTrue
              ? LinearProgressIndicator(value: vantarisUpdateProgress.value)
              : const SizedBox.shrink()),
          Obx(() => vantarisUpdateError.isEmpty
              ? const SizedBox.shrink()
              : Text(vantarisUpdateError.value,
                  style: const TextStyle(color: Colors.red))),
        ],
      ),
      actions: [
        dialogButton('Más tarde', isOutline: true, onPressed: () => close(false)),
        dialogButton('Actualizar ahora', onPressed: () async {
          if (vantarisUpdateBusy.isTrue) return;
          final done = await _installWindows(m);
          if (done) close(true);
        }),
      ],
      onCancel: () => close(false),
    );
  });
  if (ok != true) {
    _postponed.add(m.build); // no volver a preguntar por esta versión hasta reabrir el programa
    _log('el técnico lo deja para más tarde');
  }
  _asking = false;
}

Future<bool> _installWindows(VantarisManifest m) async {
  vantarisUpdateBusy.value = true;
  vantarisUpdateError.value = '';
  try {
    final p = _pick(m)!;
    final zip = await _download(p, 'paquete.zip');
    final dir = Directory('${zip.parent.path}\\nueva');
    await dir.create();
    final tar = '${Platform.environment['SystemRoot'] ?? 'C:\\Windows'}\\System32\\tar.exe';
    final r = await Process.run(tar, ['-xf', zip.path, '-C', dir.path]);
    if (r.exitCode != 0) throw 'no se pudo descomprimir: ${r.stderr}';
    final exe = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .firstWhere(
            (s) => RegExp(r'\\vantaris-[^\\]*\.exe$', caseSensitive: false).hasMatch(s),
            orElse: () => '');
    if (exe.isEmpty) throw 'el paquete no trae el programa';
    if (bind.mainIsInstalled()) {
      // Mismo camino que usa RustDesk: «<nuevo>.exe --update» copia la carpeta sobre la instalada y
      // vuelve a arrancar. Necesita administrador: Windows pedirá permiso (UAC).
      _log('instalado: lanzo --update con permisos de administrador');
      final r2 = await Process.run('powershell.exe', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "Start-Process -FilePath '${exe.replaceAll("'", "''")}' -ArgumentList '--update' -Verb RunAs"
      ]);
      if (r2.exitCode != 0) throw 'no se dio permiso de administrador';
      return true;
    }
    // Portable: un .cmd espera a que se cierre este proceso, copia la carpeta nueva encima y arranca.
    final cur = File(Platform.resolvedExecutable).parent.path;
    final newExe = exe.substring(exe.lastIndexOf('\\') + 1);
    final script = File('${zip.parent.path}\\actualizar.cmd');
    await script.writeAsString([
      '@echo off',
      'chcp 65001 >nul',
      ':espera',
      'tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul && (timeout /t 1 /nobreak >nul & goto espera)',
      'robocopy "${dir.path}" "$cur" /E /R:5 /W:1 /NFL /NDL /NJH /NJS >nul',
      'start "" "$cur\\$newExe"',
      ''
    ].join('\r\n'));
    _log('portable: copio encima de $cur y reinicio');
    await Process.start('cmd.exe', ['/c', script.path],
        mode: ProcessStartMode.detached);
    await rustDeskWinManager.closeAllSubWindows();
    exit(0);
  } catch (e) {
    _log('error al actualizar: $e');
    vantarisUpdateError.value = 'No se pudo actualizar: $e';
    return false;
  } finally {
    vantarisUpdateBusy.value = false;
  }
}

// ---------------------------------------------------------------- Soporte (Android)

const _android = MethodChannel('mChannel');

/// Descarga, comprueba y abre el instalador del sistema. El usuario confirma en la pantalla de Android.
Future<void> vantarisInstallAndroid() async {
  final m = vantarisUpdateAvailable.value;
  if (kVantarisPlay || m == null || vantarisUpdateBusy.isTrue) return;
  if (gFFI.serverModel.clients.isNotEmpty) {
    vantarisUpdateError.value = 'Hay un técnico conectado: se actualizará cuando termine.';
    return;
  }
  vantarisUpdateBusy.value = true;
  vantarisUpdateError.value = '';
  try {
    final apk = await _download(_pick(m)!, 'vantaris.apk');
    final r = await _android.invokeMethod<String>('vantaris_install_apk', apk.path);
    _log('instalador: $r');
    if (r == 'permiso') {
      vantarisUpdateError.value =
          'Permite «Instalar aplicaciones desconocidas» para Vantaris y vuelve a pulsar Actualizar.';
    }
  } catch (e) {
    _log('error al actualizar: $e');
    vantarisUpdateError.value = 'No se pudo actualizar: $e';
  } finally {
    vantarisUpdateBusy.value = false;
  }
}

/// Aviso discreto de la pantalla principal de Android. No sale con un técnico conectado.
class VantarisUpdateBanner extends StatelessWidget {
  const VantarisUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final m = vantarisUpdateAvailable.value;
      if (kVantarisPlay || m == null || gFFI.serverModel.clients.isNotEmpty) {
        return const SizedBox.shrink();
      }
      return Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.system_update, size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('Hay una versión nueva de Vantaris (${m.version}, ${m.build})')),
                if (vantarisUpdateBusy.isFalse)
                  TextButton(
                      onPressed: vantarisInstallAndroid,
                      child: const Text('Actualizar')),
              ]),
              if (m.notas.isNotEmpty)
                Text(m.notas, style: Theme.of(context).textTheme.bodySmall),
              if (vantarisUpdateBusy.isTrue)
                LinearProgressIndicator(value: vantarisUpdateProgress.value),
              if (vantarisUpdateError.isNotEmpty)
                Text(vantarisUpdateError.value,
                    style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------- Soporte (Windows): «hay asistencia»

DateTime _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);
bool _beating = false;

/// Lo llama el proceso --cm (una vez por medio segundo). Mientras haya clientes conectados deja
/// %ProgramData%\Vantaris\sesion-activa con la hora; el actualizador del runner no instala si es
/// reciente. Es solo una señal de «ahora no» (lo peor que puede hacer alguien que la toque es
/// retrasar una actualización).
void vantarisSessionHeartbeat(bool active) {
  if (!isWindows) return;
  final pd = Platform.environment['ProgramData'];
  if (pd == null) return;
  final f = File('$pd\\Vantaris\\sesion-activa');
  try {
    if (active) {
      if (DateTime.now().difference(_lastBeat).inSeconds < 10) return;
      _lastBeat = DateTime.now();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(DateTime.now().toUtc().toIso8601String(), flush: true);
      _beating = true;
    } else if (_beating) {
      _beating = false;
      if (f.existsSync()) f.deleteSync();
    }
  } catch (_) {}
}

/// Las casillas de actualización de RustDesk se ocultan (settings de escritorio y móvil).
const kVantarisOwnUpdates = true;
