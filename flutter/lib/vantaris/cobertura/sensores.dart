// Vantaris Cobertura: lecturas de radio y de red del equipo.
//
// Android: WiFi, red móvil, redes de alrededor y router los da VantarisCobertura.kt por el canal
// «mChannel» (orden «vantaris_cobertura»). Windows: `netsh wlan` y `route print`. Ping y prueba de
// velocidad son comunes (Dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'modelo.dart';

class Lectura<T> {
  final T? valor;
  final String? error;
  const Lectura(this.valor, [this.error]);
}

abstract class Sensores {
  static Sensores? _actual;

  static Sensores get actual =>
      _actual ??= Platform.isAndroid ? SensoresAndroid() : SensoresWindows();

  /// Si el equipo puede leer la red móvil (Android con SIM).
  Future<bool> tieneMovil();

  /// WiFi conectada ahora. [error] explica qué falta (permiso de ubicación…).
  Future<Lectura<LecturaWifi>> wifi();

  Future<LecturaMovil?> movil();

  /// Redes WiFi visibles.
  Future<Lectura<List<RedWifi>>> redes();

  /// IP del router (puerta de enlace por defecto).
  Future<String?> puertaEnlace();

  /// Pide los permisos necesarios (ubicación en Android).
  Future<void> pedirPermisos();

  /// Abre los ajustes del sistema donde se da el permiso de ubicación.
  Future<void> abrirAjustes();
}

// ---------------------------------------------------------------- Android

const _mChannel = MethodChannel('mChannel');

class SensoresAndroid extends Sensores {
  Future<Map<String, dynamic>> _orden(String orden) async {
    try {
      final r = await _mChannel.invokeMethod<String>('vantaris_cobertura', jsonEncode({'orden': orden}));
      return jsonDecode(r ?? '{}') as Map<String, dynamic>;
    } catch (e) {
      return {'error': 'Fallo del equipo: $e'};
    }
  }

  bool? _movil;

  @override
  Future<bool> tieneMovil() async => _movil ??= (await _orden('tiene_movil'))['si'] == true;

  @override
  Future<Lectura<LecturaWifi>> wifi() async {
    final r = await _orden('wifi');
    return Lectura(LecturaWifi.fromJson(r['wifi']), r['error'] as String?);
  }

  @override
  Future<LecturaMovil?> movil() async => LecturaMovil.fromJson((await _orden('movil'))['movil']);

  @override
  Future<Lectura<List<RedWifi>>> redes() async {
    final r = await _orden('redes');
    final l = [
      for (final x in (r['redes'] as List? ?? const [])) RedWifi.fromJson(x)
    ].whereType<RedWifi>().toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Lectura(l, r['error'] as String?);
  }

  @override
  Future<String?> puertaEnlace() async => (await _orden('router'))['ip'] as String?;

  @override
  Future<void> pedirPermisos() => _orden('permisos');

  @override
  Future<void> abrirAjustes() => _orden('ajustes');
}

// ---------------------------------------------------------------- Windows

/// La salida de netsh va en la página de códigos OEM (850 en España): lo justo para leerla.
const _cp850 = {
  0x80: 'Ç', 0x81: 'ü', 0x82: 'é', 0x83: 'â', 0x84: 'ä', 0x85: 'à', 0x87: 'ç', 0x88: 'ê',
  0x8A: 'è', 0x8B: 'ï', 0x8C: 'î', 0x8D: 'ì', 0x90: 'É', 0x93: 'ô', 0x94: 'ö', 0x95: 'ò',
  0x96: 'û', 0x97: 'ù', 0x9A: 'Ü', 0xA0: 'á', 0xA1: 'í', 0xA2: 'ó', 0xA3: 'ú', 0xA4: 'ñ',
  0xA5: 'Ñ', 0xA6: 'ª', 0xA7: 'º', 0xA8: '¿', 0xAD: '¡', 0xB5: 'Á', 0xD6: 'Í', 0xE0: 'Ó',
  0xE9: 'Ú',
};

String _oem(List<int> b) {
  final s = StringBuffer();
  for (final c in b) {
    s.write(c < 0x80 ? String.fromCharCode(c) : (_cp850[c] ?? '?'));
  }
  return s.toString();
}

class SensoresWindows extends Sensores {
  static const _avisoUbicacion =
      'Windows pide permiso de ubicación para leer la WiFi: Configuración › Privacidad y seguridad › '
      'Ubicación › activa «Permitir que las aplicaciones de escritorio accedan a tu ubicación».';

  static final _reLinea = RegExp(r'^\s*([^:]+?)\s+:\s?(.*)$');

  Future<String?> _ejecutar(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args, stdoutEncoding: null, stderrEncoding: null)
          .timeout(const Duration(seconds: 10));
      return _oem([...(r.stdout as List<int>), ...(r.stderr as List<int>)]);
    } catch (_) {
      return null;
    }
  }

  /// Normaliza la clave: minúsculas, sin acentos ni caracteres raros.
  static String _clave(String k) {
    const acentos = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ü': 'u'};
    final b = StringBuffer();
    for (final ch in k.toLowerCase().split('')) {
      final c = acentos[ch] ?? ch;
      if (RegExp(r'[a-z ()]').hasMatch(c)) b.write(c);
    }
    return b.toString().trim();
  }

  static bool _faltaUbicacion(String t) {
    final l = t.toLowerCase();
    return l.contains('location') || l.contains('ubicaci');
  }

  static int? _digitos(String? v) => v == null ? null : int.tryParse(v.replaceAll(RegExp(r'[^0-9]'), ''));

  static int? _frecuencia(int? canal, String? banda) {
    if (canal == null) return null;
    if (banda != null && banda.trim().startsWith('6')) return 5950 + canal * 5;
    if (canal >= 1 && canal <= 13) return 2407 + canal * 5;
    if (canal == 14) return 2484;
    return 5000 + canal * 5;
  }

  @override
  Future<bool> tieneMovil() async => false;

  @override
  Future<Lectura<LecturaWifi>> wifi() async {
    final txt = await _ejecutar('netsh', ['wlan', 'show', 'interfaces']);
    if (txt == null) return const Lectura(null, 'No se pudo ejecutar netsh');
    final campos = <String, String>{};
    for (final l in const LineSplitter().convert(txt)) {
      final m = _reLinea.firstMatch(l);
      if (m == null) continue;
      campos.putIfAbsent(_clave(m.group(1)!), () => m.group(2)!.trim());
    }
    String? busca(List<String> raices) {
      for (final e in campos.entries) {
        if (raices.any((r) => e.key == r || e.key.startsWith('$r ') || e.key.startsWith('$r('))) {
          return e.value;
        }
      }
      return null;
    }

    final estado = busca(['estado', 'state']);
    final ssid = busca(['ssid']);
    if (ssid == null) {
      return Lectura(null, _faltaUbicacion(txt) ? _avisoUbicacion : null);
    }
    if (estado != null) {
      final e = estado.toLowerCase();
      if (!e.contains('conect') && !e.contains('connected')) return const Lectura(null);
    }
    final pct = _digitos(busca(['senal', 'seal', 'signal', 'se al']));
    final rssiDirecto = int.tryParse(busca(['rssi'])?.trim() ?? '');
    final canal = _digitos(busca(['canal', 'channel']));
    String? rx;
    for (final e in campos.entries) {
      if (e.key.contains('recep') || e.key.contains('receive')) {
        rx = e.value;
        break;
      }
    }
    return Lectura(LecturaWifi(
      ssid: ssid,
      bssid: busca(['bssid']) ?? busca(['ap bssid']),
      // Windows da calidad 0-100 %; la equivalencia habitual es dBm = calidad/2 - 100.
      rssi: rssiDirecto ?? (pct != null ? pct ~/ 2 - 100 : null),
      frecuenciaMhz: _frecuencia(canal, busca(['banda', 'band'])),
      canal: canal,
      velocidadMbps: double.tryParse(rx?.replaceAll(',', '.') ?? ''),
      estandar: busca(['tipo de radio', 'radio type']),
    ));
  }

  @override
  Future<LecturaMovil?> movil() async => null;

  @override
  Future<Lectura<List<RedWifi>>> redes() async {
    final txt = await _ejecutar('netsh', ['wlan', 'show', 'networks', 'mode=bssid']);
    if (txt == null) return const Lectura(null, 'No se pudo ejecutar netsh');
    final lista = <RedWifi>[];
    var ssid = '';
    String? bssid, banda;
    int? senal, canal;
    void cerrar() {
      if (bssid != null && senal != null) {
        lista.add(RedWifi(ssid.isEmpty ? '(oculta)' : ssid, bssid!, senal! ~/ 2 - 100,
            _frecuencia(canal, banda), canal));
      }
      bssid = null;
      senal = null;
      canal = null;
      banda = null;
    }

    for (final l in const LineSplitter().convert(txt)) {
      final m = _reLinea.firstMatch(l);
      if (m == null) continue;
      final k = _clave(m.group(1)!);
      final v = m.group(2)!.trim();
      if (k.startsWith('ssid')) {
        cerrar();
        ssid = v;
      } else if (k.startsWith('bssid')) {
        cerrar();
        bssid = v;
      } else if (k.startsWith('senal') || k.startsWith('seal') || k.startsWith('signal') || k.startsWith('se al')) {
        senal = _digitos(v);
      } else if (k.startsWith('canal') || k.startsWith('channel')) {
        canal = _digitos(v);
      } else if (k.startsWith('banda') || k.startsWith('band')) {
        banda = v;
      }
    }
    cerrar();
    if (lista.isEmpty && _faltaUbicacion(txt)) return const Lectura(null, _avisoUbicacion);
    lista.sort((a, b) => b.rssi.compareTo(a.rssi));
    return Lectura(lista);
  }

  @override
  Future<String?> puertaEnlace() async {
    final txt = await _ejecutar('route', ['print', '-4', '0.0.0.0']);
    if (txt == null) return null;
    // «0.0.0.0  0.0.0.0  192.168.1.1  192.168.1.134  35». Puede haber varias (VPN, adaptadores
    // virtuales): gana la de menor métrica.
    final re = RegExp(r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+\S+\s+(\d+)', multiLine: true);
    String? mejor;
    var metrica = 1 << 30;
    for (final m in re.allMatches(txt)) {
      final k = int.tryParse(m.group(2)!) ?? (1 << 30);
      if (k < metrica) {
        metrica = k;
        mejor = m.group(1);
      }
    }
    return mejor;
  }

  @override
  Future<void> pedirPermisos() async {}

  @override
  Future<void> abrirAjustes() async {
    try {
      await Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-location'], runInShell: false);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- Red (común)

class Red {
  static final _reTiempo =
      RegExp(r'(?:time|tiempo|zeit|temps|tempo)\s*[=<]\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false);

  /// null = aún no se sabe; false = el ping del sistema no funciona aquí y se usa TCP.
  static bool? _pingSistema;

  /// Tiempo de ida y vuelta en ms, o null si no responde.
  static Future<double?> ping(String host, {int timeoutMs = 1500}) async {
    if (_pingSistema != false) {
      final r = await _pingDelSistema(host, timeoutMs);
      if (r != null) {
        _pingSistema = true;
        return r.valor;
      }
      _pingSistema = false;
    }
    return _pingTcp(host, timeoutMs);
  }

  /// Lectura(null) = sin respuesta (paquete perdido); null = el comando no sirve aquí.
  static Future<Lectura<double>?> _pingDelSistema(String host, int timeoutMs) async {
    final List<String> cmd = Platform.isWindows
        ? ['ping', '-n', '1', '-w', '$timeoutMs', host]
        : ['/system/bin/ping', '-c', '1', '-W', '${(timeoutMs ~/ 1000).clamp(1, 10)}', host];
    try {
      final r = await Process.run(cmd.first, cmd.sublist(1), stdoutEncoding: latin1, stderrEncoding: latin1)
          .timeout(Duration(milliseconds: timeoutMs + 2500));
      final txt = '${r.stdout}${r.stderr}';
      final m = _reTiempo.firstMatch(txt);
      if (m != null) return Lectura(double.tryParse(m.group(1)!.replaceAll(',', '.')));
      final l = txt.toLowerCase();
      // Sin permiso para ICMP (algunos Android) o comando inexistente: usar TCP.
      if (l.contains('permission') || l.contains('not permitted') || (l.contains('unknown') && l.contains('option'))) {
        return null;
      }
      return const Lectura(null);
    } on TimeoutException {
      return const Lectura(null);
    } catch (_) {
      return null;
    }
  }

  /// «Ping» por TCP: tiempo en abrir conexión al 443 (o 80, 53). Un rechazo también cuenta como respuesta.
  static Future<double?> _pingTcp(String host, int timeoutMs) async {
    for (final puerto in const [443, 80, 53]) {
      final sw = Stopwatch()..start();
      try {
        final s = await Socket.connect(host, puerto, timeout: Duration(milliseconds: timeoutMs));
        s.destroy();
        return sw.elapsedMicroseconds / 1000.0;
      } on SocketException catch (e) {
        final ms = sw.elapsedMicroseconds / 1000.0;
        final rechazo = e.osError?.errorCode == 111 || e.osError?.errorCode == 10061;
        if (rechazo && ms < timeoutMs) return ms;
      } catch (_) {}
    }
    return null;
  }

  /// Lanza [n] pings seguidos y resume.
  static Future<ResultadoPing> serie(String host, {int n = 5, int pausaMs = 150}) async {
    final tiempos = <double>[];
    for (var i = 0; i < n; i++) {
      final t = await ping(host);
      if (t != null) tiempos.add(t);
      if (i < n - 1) await Future.delayed(Duration(milliseconds: pausaMs));
    }
    return resumirPing(host, n, tiempos);
  }

  /// Prueba de descarga; devuelve Mbps o null si no hay conexión.
  static Future<double?> velocidad({int segundos = 5, void Function(double mbps)? progreso}) async {
    final cliente = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await cliente.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=100000000'));
      req.headers.set(HttpHeaders.userAgentHeader, 'VantarisSoporte-Cobertura/1.0');
      final res = await req.close().timeout(const Duration(seconds: 6));
      var total = 0;
      final sw = Stopwatch()..start();
      final limite = Duration(seconds: segundos);
      final hecho = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = res.listen((trozo) {
        total += trozo.length;
        final s = sw.elapsedMicroseconds / 1e6;
        if (s > 0.3) progreso?.call(total * 8 / s / 1e6);
        if (sw.elapsed >= limite && !hecho.isCompleted) {
          sub.cancel();
          hecho.complete();
        }
      }, onDone: () {
        if (!hecho.isCompleted) hecho.complete();
      }, onError: (_) {
        if (!hecho.isCompleted) hecho.complete();
      }, cancelOnError: true);
      await hecho.future.timeout(limite + const Duration(seconds: 5), onTimeout: () => sub.cancel());
      final s = sw.elapsedMicroseconds / 1e6;
      if (total == 0 || s <= 0) return null;
      return total * 8 / s / 1e6;
    } catch (_) {
      return null;
    } finally {
      cliente.close(force: true);
    }
  }
}

/// Toma una medición completa en el punto (x, y) del plano.
Future<Medicion> medirPunto({
  required double x,
  required double y,
  required bool conVelocidad,
  required String? router,
  required void Function(String) paso,
}) async {
  final s = Sensores.actual;
  paso('Leyendo la WiFi…');
  // Varias lecturas: la señal baila de un segundo a otro.
  final lecturas = <LecturaWifi>[];
  for (var i = 0; i < 3; i++) {
    final l = await s.wifi();
    if (l.valor != null) lecturas.add(l.valor!);
    await Future.delayed(const Duration(milliseconds: 350));
  }
  LecturaWifi? wifi;
  if (lecturas.isNotEmpty) {
    final r = lecturas.map((e) => e.rssi).whereType<int>().toList();
    wifi = lecturas.last.conRssi(r.isEmpty ? null : (r.reduce((a, b) => a + b) / r.length).round());
  }
  LecturaMovil? movil;
  if (await s.tieneMovil()) {
    paso('Leyendo la red móvil…');
    movil = await s.movil();
  }
  ResultadoPing? pRouter;
  if (router != null) {
    paso('Ping al router…');
    pRouter = await Red.serie(router, n: 5);
  }
  paso('Ping a internet…');
  final pInternet = await Red.serie(kHostInternet, n: 6);
  double? vel;
  if (conVelocidad) {
    paso('Prueba de velocidad…');
    vel = await Red.velocidad(progreso: (m) => paso('Prueba de velocidad… ${fmt(m, 1)} Mbps'));
  }
  final ahora = DateTime.now().millisecondsSinceEpoch;
  return Medicion(
    id: ahora,
    x: x,
    y: y,
    instante: ahora,
    wifi: wifi,
    movil: movil,
    pingRouter: pRouter,
    pingInternet: pInternet,
    velocidadMbps: vel,
  );
}
