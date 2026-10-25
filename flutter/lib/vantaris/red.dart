// Vantaris: red del local, impresoras y cajón SIN depender de la app TPV (lado equipo; ver diag.dart).
//
// Lo pide el técnico desde el panel de diagnóstico y lo hace el equipo del cliente:
//   red                 qué equipos hay en la red del local y qué son (fabricante, tipo, modelo, S.O.)
//   ping <ip>           ping de 4 paquetes (si no hay ping o no contesta: conexión TCP a puertos típicos)
//   imprimirip <ip>     ticket de prueba ESC/POS por TCP 9100 (impresora de tickets de red)
//   cajonip <ip>        pulso de apertura del cajón por la impresora de red (patillas 2 y 5)
//   impresoras          (Windows) impresoras instaladas en el equipo
//   imprimirlocal <n>   (Windows) ticket de prueba a la impresora n de esa lista, en RAW por el spooler
//   cajonlocal <n>      (Windows) pulso del cajón por la impresora n
// Solo IPs privadas (10/8, 172.16/12, 192.168/16, 169.254/16): el equipo no se puede usar para tocar
// nada fuera de su red local. Las órdenes del sistema (ping, arp, route) van con argumentos fijos.
// El escaneo es suave: la /24 de cada interfaz, conexiones TCP cortas con concurrencia limitada.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as w;

import 'oui.dart';

/// Órdenes de este fichero (entran en la lista blanca de diag.dart).
const kVantarisRedOrders = {
  'red', 'ping', 'imprimirip', 'cajonip', 'impresoras', 'imprimirlocal', 'cajonlocal'
};

/// Argumento válido para cada orden (null = sin argumento).
bool vantarisRedArgValido(String orden, String? arg) {
  switch (orden) {
    case 'red':
    case 'impresoras':
      return arg == null;
    case 'ping':
    case 'imprimirip':
    case 'cajonip':
      return arg != null && vantarisIpPrivada(arg);
    case 'imprimirlocal':
    case 'cajonlocal':
      return arg != null && RegExp(r'^[0-9]{1,3}$').hasMatch(arg);
  }
  return false;
}

Future<Map<String, dynamic>> vantarisRedRun(String orden, String? arg) async {
  switch (orden) {
    case 'red':
      return vantarisEscanearRed();
    case 'ping':
      return vantarisPing(arg!);
    case 'imprimirip':
      return _enviar9100(arg!, vantarisTicketPrueba(destino: '$arg:9100'), 'Ticket de prueba enviado a $arg.');
    case 'cajonip':
      return _enviar9100(arg!, [...vantarisPulsoCajon(0), ...vantarisPulsoCajon(1)],
          'Pulso de apertura enviado al cajón por la impresora $arg.');
    case 'impresoras':
      if (!isWindowsEquipo) return _soloWindows;
      return _impresorasWindows();
    case 'imprimirlocal':
    case 'cajonlocal':
      if (!isWindowsEquipo) return _soloWindows;
      return _rawWindows(int.parse(arg!), orden == 'cajonlocal');
  }
  return {'ok': false, 'motivo': 'Orden no permitida.'};
}

bool get isWindowsEquipo => Platform.isWindows;

const _soloWindows = {'ok': false, 'motivo': 'Solo en equipos Windows.'};

// ---------------------------------------------------------------- direcciones

int? _ipNum(String s) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s);
  if (m == null) return null;
  var n = 0;
  for (var i = 1; i <= 4; i++) {
    final g = m.group(i)!;
    if (g.length > 1 && g.startsWith('0')) return null; // sin ceros a la izquierda (octal)
    final v = int.parse(g);
    if (v > 255) return null;
    n = (n << 8) | v;
  }
  return n;
}

/// IPv4 de una red privada o de enlace local, sin la de red ni la de difusión de una /24.
bool vantarisIpPrivada(String s) {
  final n = _ipNum(s);
  if (n == null) return false;
  final a = n >> 24, b = (n >> 16) & 0xFF, last = n & 0xFF;
  final privada = a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
      (a == 169 && b == 254);
  return privada && last != 0 && last != 255;
}

// ---------------------------------------------------------------- ESC/POS

/// Quita tildes y símbolos: cada impresora trae una página de códigos distinta y el ASCII sale en todas.
String _ascii(String s) {
  const de = 'áàäâÁÀÄÂéèëêÉÈËÊíìïîÍÌÏÎóòöôÓÒÖÔúùüûÚÙÜÛñÑçÇ·';
  const a = 'aaaaAAAAeeeeEEEEiiiiIIIIooooOOOOuuuuUUUUnNcC.';
  final b = StringBuffer();
  for (final ch in s.runes) {
    final c = String.fromCharCode(ch);
    final i = de.indexOf(c);
    b.write(i >= 0 ? a[i] : (ch < 0x80 ? c : '?'));
  }
  return b.toString();
}

/// Ticket de prueba: inicializar, título grande centrado, fecha, equipo y destino, avance y corte.
List<int> vantarisTicketPrueba({required String destino, DateTime? ahora}) {
  final t = ahora ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final fecha = '${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}';
  List<int> txt(String s) => latin1.encode('${_ascii(s)}\n');
  return [
    0x1B, 0x40, // ESC @  inicializar
    0x1B, 0x61, 0x01, // ESC a 1  centrado
    0x1D, 0x21, 0x11, // GS ! doble alto y ancho
    0x1B, 0x45, 0x01, // ESC E 1  negrita
    ...txt('VANTARIS'),
    0x1D, 0x21, 0x00, 0x1B, 0x45, 0x00,
    ...txt('Soporte remoto'),
    ...txt('--------------------------------'),
    ...txt('TICKET DE PRUEBA'),
    ...txt(fecha),
    0x1B, 0x61, 0x00, // izquierda
    ...txt('Equipo: ${Platform.localHostname}'),
    ...txt('Impresora: $destino'),
    ...txt(''),
    0x1B, 0x61, 0x01,
    ...txt('Si lees esto, la impresora'),
    ...txt('funciona bien.'),
    0x1B, 0x64, 0x05, // ESC d 5  avanzar 5 líneas
    0x1D, 0x56, 0x42, 0x00, // GS V B 0  corte parcial (las que no cortan lo ignoran)
  ];
}

/// Pulso de apertura del cajón: ESC p m t1 t2 (m = 0 patilla 2, 1 patilla 5; 50 ms / 500 ms).
List<int> vantarisPulsoCajon(int patilla) => [0x1B, 0x70, patilla, 0x19, 0xFA];

Future<Map<String, dynamic>> _enviar9100(String ip, List<int> datos, String ok) async {
  Socket? s;
  try {
    s = await Socket.connect(ip, 9100, timeout: const Duration(seconds: 4));
    s.add(datos);
    await s.flush();
    await s.close();
    return {'ok': true, 'mensaje': ok};
  } on SocketException catch (e) {
    return {'ok': false, 'motivo': 'La impresora $ip no acepta conexiones por el puerto 9100 (${_errorRed(e)}).'};
  } catch (e) {
    return {'ok': false, 'motivo': 'No se ha podido enviar a $ip: $e'};
  } finally {
    s?.destroy();
  }
}

String _errorRed(SocketException e) {
  if (_rechazada(e)) return 'rechazada: el equipo existe pero no es una impresora de red o no usa ese puerto';
  return 'no contesta';
}

/// Conexión rechazada (RST): el equipo está ahí aunque el puerto esté cerrado.
bool _rechazada(SocketException e) {
  final c = e.osError?.errorCode;
  return c == 10061 || c == 111 || c == 61;
}

// ---------------------------------------------------------------- ping

final _reWin = RegExp(r'[=<](\d+)\s*ms?\s+TTL=(\d+)', caseSensitive: false);
final _reNix = RegExp(r'ttl=(\d+)\s+time[=<]([\d.]+)\s*ms', caseSensitive: false);

/// (milisegundos, ttl) de cada respuesta de la salida de ping (Windows en cualquier idioma, Linux/Android).
List<(double, int)> vantarisLeerPing(String salida) {
  final out = <(double, int)>[];
  for (final m in _reWin.allMatches(salida)) {
    out.add((double.parse(m.group(1)!), int.parse(m.group(2)!)));
  }
  if (out.isEmpty) {
    for (final m in _reNix.allMatches(salida)) {
      out.add((double.parse(m.group(2)!), int.parse(m.group(1)!)));
    }
  }
  return out;
}

Future<List<(double, int)>> _pingSistema(String ip, int veces) async {
  try {
    final r = Platform.isWindows
        ? await Process.run('ping', ['-n', '$veces', '-w', '1000', ip])
        : await Process.run('ping', ['-c', '$veces', '-W', '1', ip]);
    return vantarisLeerPing('${r.stdout}');
  } catch (_) {
    return [];
  }
}

const _kPuertosVida = [80, 443, 9100, 445, 22, 554, 8080, 5555, 62078, 139];

/// ¿Responde por TCP? Devuelve los ms de la primera conexión (aceptada o rechazada) o null.
Future<int?> _tcpVivo(String ip, List<int> puertos, Duration espera) async {
  final sw = Stopwatch()..start();
  final c = Completer<int?>();
  var pendientes = puertos.length;
  for (final p in puertos) {
    Socket.connect(ip, p, timeout: espera).then((s) {
      s.destroy();
      if (!c.isCompleted) c.complete(sw.elapsedMilliseconds);
    }, onError: (e) {
      if (e is SocketException && _rechazada(e) && !c.isCompleted) c.complete(sw.elapsedMilliseconds);
      if (--pendientes == 0 && !c.isCompleted) c.complete(null);
    });
  }
  return c.future;
}

Future<Map<String, dynamic>> vantarisPing(String ip) async {
  final r = await _pingSistema(ip, 4);
  if (r.isNotEmpty) {
    final ms = r.map((e) => e.$1).toList();
    final media = ms.reduce((a, b) => a + b) / ms.length;
    final perdidos = 4 - r.length;
    return {
      'ok': true,
      'ip': ip,
      'responde': true,
      'metodo': 'ping',
      'recibidos': r.length,
      'enviados': 4,
      'ms': ms,
      'ttl': r.first.$2,
      'mensaje': '$ip responde: ${r.length}/4 paquetes, ${media.toStringAsFixed(0)} ms de media '
          '(mín. ${ms.reduce(min).toStringAsFixed(0)}, máx. ${ms.reduce(max).toStringAsFixed(0)})'
          '${perdidos > 0 ? ', $perdidos perdidos' : ''}.',
    };
  }
  final t = await _tcpVivo(ip, _kPuertosVida, const Duration(seconds: 2));
  if (t != null) {
    return {
      'ok': true,
      'ip': ip,
      'responde': true,
      'metodo': 'tcp',
      'ms': [t],
      'mensaje': '$ip no contesta al ping pero está en la red (responde por TCP en $t ms).',
    };
  }
  return {
    'ok': true,
    'ip': ip,
    'responde': false,
    'mensaje': '$ip NO responde (ni al ping ni por TCP): apagado, desconectado o en otra red.',
  };
}

// ---------------------------------------------------------------- identificación

/// Consulta NetBIOS de estado (UDP 137): nombre del equipo Windows/Samba y su MAC.
List<int> vantarisNbstatPeticion(int id) => [
      id >> 8 & 0xFF, id & 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x20, 0x43, 0x4B, ...List.filled(30, 0x41), 0x00, // «*» codificado
      0x00, 0x21, 0x00, 0x01, // NBSTAT, IN
    ];

/// (nombre, mac) de una respuesta NBSTAT, o null.
(String?, String?)? vantarisLeerNbstat(Uint8List d) {
  try {
    if (d.length < 57) return null;
    var i = 12;
    if (d[i] & 0xC0 == 0xC0) {
      i += 2;
    } else {
      while (i < d.length && d[i] != 0) {
        i += d[i] + 1;
      }
      i += 1;
    }
    i += 10; // tipo, clase, ttl, longitud
    final n = d[i];
    i += 1;
    String? nombre;
    for (var k = 0; k < n && i + 18 <= d.length; k++, i += 18) {
      final sufijo = d[i + 15];
      final grupo = d[i + 16] & 0x80 != 0;
      if (nombre == null && sufijo == 0x00 && !grupo) {
        nombre = latin1.decode(d.sublist(i, i + 15)).trim();
      }
    }
    String? mac;
    if (i + 6 <= d.length) {
      final b = d.sublist(i, i + 6);
      if (b.any((x) => x != 0)) mac = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join('-');
    }
    return (nombre, mac);
  } catch (_) {
    return null;
  }
}

// SNMP v1 (comunidad «public»): sysDescr y sysName; y aparte hrDeviceDescr (modelo de muchas impresoras).
const _oidSysDescr = [0x2B, 6, 1, 2, 1, 1, 1, 0];
const _oidSysName = [0x2B, 6, 1, 2, 1, 1, 5, 0];
const _oidHrDevice = [0x2B, 6, 1, 2, 1, 25, 3, 2, 1, 3, 1];

List<int> _tlv(int tipo, List<int> v) {
  final l = v.length;
  final len = l < 0x80 ? [l] : (l < 0x100 ? [0x81, l] : [0x82, l >> 8, l & 0xFF]);
  return [tipo, ...len, ...v];
}

List<int> vantarisSnmpPeticion(int id, List<List<int>> oids) => _tlv(0x30, [
      ..._tlv(0x02, [0]), // versión 1
      ..._tlv(0x04, ascii.encode('public')),
      ..._tlv(0xA0, [
        ..._tlv(0x02, [id >> 8 & 0x7F, id & 0xFF]),
        ..._tlv(0x02, [0]),
        ..._tlv(0x02, [0]),
        ..._tlv(0x30, [for (final o in oids) ..._tlv(0x30, [..._tlv(0x06, o), 0x05, 0x00])]),
      ]),
    ]);

/// Textos (OCTET STRING) de las variables de una respuesta SNMP, en orden. Vacío si hay error.
List<String> vantarisLeerSnmp(Uint8List d) {
  final out = <String>[];
  void walk(int i, int fin) {
    while (i < fin) {
      final tipo = d[i];
      var l = d[i + 1];
      var j = i + 2;
      if (l & 0x80 != 0) {
        final n = l & 0x7F;
        l = 0;
        for (var k = 0; k < n; k++) {
          l = (l << 8) | d[j + k];
        }
        j += n;
      }
      if (j + l > fin) return;
      if (tipo == 0x30 || tipo == 0xA2) {
        walk(j, j + l);
      } else if (tipo == 0x04 && out.length < 8) {
        out.add(utf8.decode(d.sublist(j, j + l), allowMalformed: true).trim());
      }
      i = j + l;
    }
  }

  try {
    walk(0, d.length);
  } catch (_) {}
  // El primer OCTET STRING es la comunidad.
  return out.length > 1 ? out.sublist(1) : [];
}

Future<Uint8List?> _udp(String ip, int puerto, List<int> datos, Duration espera) async {
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final c = Completer<Uint8List?>();
    s.listen((ev) {
      if (ev == RawSocketEvent.read) {
        final dg = s!.receive();
        if (dg != null && dg.address.address == ip && !c.isCompleted) c.complete(dg.data);
      }
    });
    s.send(datos, InternetAddress(ip), puerto);
    return await c.future.timeout(espera, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    s?.close();
  }
}

Future<String?> _tituloWeb(String ip) async {
  Socket? s;
  try {
    s = await Socket.connect(ip, 80, timeout: const Duration(milliseconds: 800));
    s.add(ascii.encode('GET / HTTP/1.0\r\nHost: $ip\r\nUser-Agent: VantarisSoporte\r\n\r\n'));
    final b = BytesBuilder();
    await for (final chunk in s.timeout(const Duration(milliseconds: 1500))) {
      b.add(chunk);
      if (b.length > 32768) break;
    }
    final html = latin1.decode(b.takeBytes());
    final m = RegExp(r'<title[^>]*>([^<]{1,120})</title>', caseSensitive: false).firstMatch(html);
    final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (t == null || t.isEmpty) ? null : t;
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}

// ---------------------------------------------------------------- escaneo

const _kPuertos = [80, 443, 9100, 515, 631, 445, 139, 3389, 22, 5555, 62078, 8080, 554, 7000];

/// Corre [tareas] con [n] a la vez como mucho.
Future<void> _enParalelo<T>(List<T> items, int n, Future<void> Function(T) tarea) async {
  var i = 0;
  Future<void> obrero() async {
    while (i < items.length) {
      await tarea(items[i++]);
    }
  }

  await Future.wait([for (var k = 0; k < min(n, items.length); k++) obrero()]);
}

Future<Map<String, String>> _arp() async {
  final out = <String, String>{};
  final re = RegExp(r'(\d+\.\d+\.\d+\.\d+)\s+(?:\S+\s+)?([0-9a-fA-F]{2}(?:[-:][0-9a-fA-F]{2}){5})');
  String texto = '';
  try {
    if (Platform.isWindows) {
      texto = '${(await Process.run('arp', ['-a'])).stdout}';
    } else {
      // Android 10+ no deja leerla; en los anteriores sí.
      texto = await File('/proc/net/arp').readAsString();
    }
  } catch (_) {}
  for (final m in re.allMatches(texto)) {
    final mac = m.group(2)!.toLowerCase().replaceAll(':', '-');
    if (mac == 'ff-ff-ff-ff-ff-ff' || mac.startsWith('01-00-5e') || mac == '00-00-00-00-00-00') continue;
    out[m.group(1)!] = mac;
  }
  return out;
}

/// Puertas de enlace por defecto (Windows; puede haber varias con VPN o adaptadores virtuales).
Future<List<String>> _puertasEnlace() async {
  if (!Platform.isWindows) return [];
  try {
    final r = await Process.run('route', ['print', '-4', '0.0.0.0']);
    return RegExp(r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)', multiLine: true)
        .allMatches('${r.stdout}')
        .map((m) => m.group(1)!)
        .toList();
  } catch (_) {
    return [];
  }
}

const _kMarcasImpresora = {
  'Epson', 'Star', 'Bixolon', 'Citizen', 'Rongta', 'Brother', 'Canon', 'Kyocera', 'Ricoh', 'Lexmark',
  'OKI', 'Zebra', 'Sharp'
};
const _kMarcasTpv = {'Sunmi', 'iMin', 'Posiflex', 'Partner Tech', 'Elo'};
const _kMarcasDatafono = {'PAX', 'Ingenico', 'Verifone'};
const _kMarcasRouter = {
  'TP-Link', 'ZTE', 'Tenda', 'Ubiquiti', 'Sagemcom', 'MitraStar', 'Askey', 'Netgear', 'D-Link', 'Cisco',
  'MikroTik', 'Fortinet', 'Huawei'
};
const _kMarcasMovil = {'Samsung', 'Xiaomi', 'OPPO', 'vivo', 'OnePlus', 'realme', 'Motorola', 'Huawei'};

/// Tipo, modelo y sistema de un equipo a partir de lo averiguado. Lo que no es seguro va «(estimado)».
Map<String, String?> vantarisClasificar({
  required Set<int> puertos,
  String? fabricante,
  String? snmp,
  String? modeloSnmp,
  String? titulo,
  String? netbios,
  int? ttl,
  bool puertaEnlace = false,
}) {
  final txt = '${snmp ?? ''} ${modeloSnmp ?? ''} ${titulo ?? ''}'.toLowerCase();
  final pareceImpresora = puertos.contains(9100) ||
      puertos.contains(515) ||
      puertos.contains(631) ||
      RegExp(r'printer|impresora|epson|tm-[a-z0-9]|star |bixolon|citizen|laserjet|officejet|'
              r'brother|kyocera|ricoh|xprinter|pos-?80|receipt')
          .hasMatch(txt) ||
      _kMarcasImpresora.contains(fabricante);
  String tipo;
  if (puertaEnlace) {
    tipo = 'router';
  } else if (pareceImpresora) {
    tipo = 'impresora';
  } else if (_kMarcasDatafono.contains(fabricante)) {
    tipo = 'datáfono';
  } else if (_kMarcasTpv.contains(fabricante)) {
    tipo = 'TPV / terminal Android';
  } else if (puertos.contains(62078)) {
    tipo = 'iPhone / iPad';
  } else if (puertos.contains(554) || fabricante == 'Hikvision' || fabricante == 'Dahua') {
    tipo = 'cámara';
  } else if (netbios != null || puertos.contains(445) || puertos.contains(3389) || puertos.contains(139)) {
    tipo = 'ordenador';
  } else if (puertos.contains(5555)) {
    tipo = 'Android';
  } else if (_kMarcasRouter.contains(fabricante) && (puertos.contains(80) || puertos.contains(443))) {
    tipo = 'router / punto de acceso (estimado)';
  } else if (_kMarcasMovil.contains(fabricante) || fabricante == 'Apple') {
    tipo = 'móvil / tablet (estimado)';
  } else if (puertos.contains(22) && (ttl == null || ttl <= 64)) {
    tipo = 'equipo Linux / servidor (estimado)';
  } else {
    tipo = 'desconocido';
  }

  String? so;
  if (snmp != null && snmp.isNotEmpty) {
    if (snmp.contains('Windows')) {
      so = 'Windows';
    } else if (RegExp(r'linux', caseSensitive: false).hasMatch(snmp)) {
      so = 'Linux';
    }
  }
  so ??= puertos.contains(62078)
      ? 'iOS'
      : (puertos.contains(3389) || puertos.contains(445) || netbios != null) && (ttl == null || ttl > 64)
          ? 'Windows (estimado)'
          : puertos.contains(5555) || _kMarcasTpv.contains(fabricante) || _kMarcasMovil.contains(fabricante)
              ? 'Android (estimado)'
              : fabricante == 'Apple'
                  ? 'iOS / macOS (estimado)'
                  : ttl == null
                      ? null
                      : ttl > 128
                          ? 'sistema propio de red (estimado)'
                          : ttl > 64
                              ? 'Windows (estimado)'
                              : 'Linux / Android / iOS (estimado)';

  String? modelo = modeloSnmp;
  if ((modelo == null || modelo.isEmpty) && snmp != null && snmp.isNotEmpty) {
    modelo = snmp.split(RegExp(r'[\r\n]')).first;
  }
  if ((modelo == null || modelo.isEmpty) && titulo != null) modelo = titulo;
  if (modelo != null && modelo.length > 80) modelo = '${modelo.substring(0, 77)}…';
  return {'tipo': tipo, 'so': so, 'modelo': modelo};
}

/// Barrido de la red del local: equipos que responden y qué son. Tarda unos 15-30 s.
Future<Map<String, dynamic>> vantarisEscanearRed() async {
  final sw = Stopwatch()..start();
  final propias = <String>{};
  final redes = <String>{}; // «a.b.c» de cada /24
  for (final nif in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in nif.addresses) {
      if (!vantarisIpPrivada(a.address) || a.address.startsWith('169.254.')) continue;
      propias.add(a.address);
      redes.add(a.address.substring(0, a.address.lastIndexOf('.')));
    }
  }
  if (redes.isEmpty) return {'ok': false, 'motivo': 'El equipo no está conectado a ninguna red local.'};
  // Con varias interfaces (VPN, máquinas virtuales…), primero la que tiene la salida a internet; dos como mucho.
  final puertas = await _puertasEnlace();
  bool conSalida(String r) => puertas.any((g) => g.startsWith('$r.'));
  final lista = (redes.toList()..sort((a, b) => (conSalida(b) ? 1 : 0) - (conSalida(a) ? 1 : 0)))
      .take(2)
      .toList();
  final gw = puertas.where((g) => lista.any((r) => g.startsWith('$r.'))).firstOrNull;

  // 1) ¿Quién está? Conexión TCP corta a los puertos típicos (aceptada o rechazada = está).
  final vivos = <String, Set<int>>{};
  final candidatos = [
    for (final r in lista)
      for (var h = 1; h < 255; h++) '$r.$h'
  ]..removeWhere(propias.contains);
  final sondas = [
    for (final ip in candidatos)
      for (final p in _kPuertos) (ip, p)
  ];
  await _enParalelo<(String, int)>(sondas, 96, (s) async {
    try {
      final so = await Socket.connect(s.$1, s.$2, timeout: const Duration(milliseconds: 350));
      so.destroy();
      vivos.putIfAbsent(s.$1, () => {}).add(s.$2);
    } on SocketException catch (e) {
      if (_rechazada(e)) vivos.putIfAbsent(s.$1, () => {});
    } catch (_) {}
  });

  // 2) La tabla ARP (Windows) saca también los que tienen todo cerrado: las conexiones de antes la llenan.
  final arp = await _arp();
  for (final ip in arp.keys) {
    if (lista.any((r) => ip.startsWith('$r.')) && !propias.contains(ip) && vantarisIpPrivada(ip)) {
      vivos.putIfAbsent(ip, () => {});
    }
  }

  // 3) Qué es cada uno.
  final equipos = <Map<String, dynamic>>[];
  var id = Random().nextInt(0x7FFF);
  await _enParalelo<String>(vivos.keys.toList(), 12, (ip) async {
    final puertos = vivos[ip]!;
    final res = await Future.wait<dynamic>([
      InternetAddress(ip).reverse().then((a) => a.host == ip ? null : a.host).timeout(
          const Duration(milliseconds: 1500),
          onTimeout: () => null).catchError((_) => null),
      _udp(ip, 137, vantarisNbstatPeticion(++id), const Duration(milliseconds: 900)),
      _udp(ip, 161, vantarisSnmpPeticion(++id, [_oidSysDescr, _oidSysName]), const Duration(milliseconds: 900)),
      _udp(ip, 161, vantarisSnmpPeticion(++id, [_oidHrDevice]), const Duration(milliseconds: 900)),
      puertos.contains(80) ? _tituloWeb(ip) : Future.value(null),
      _pingSistema(ip, 1),
    ]);
    final nb = res[1] == null ? null : vantarisLeerNbstat(res[1] as Uint8List);
    final snmp = res[2] == null ? <String>[] : vantarisLeerSnmp(res[2] as Uint8List);
    final hr = res[3] == null ? <String>[] : vantarisLeerSnmp(res[3] as Uint8List);
    final ping = res[5] as List<(double, int)>;
    final mac = arp[ip] ?? nb?.$2;
    final fabricante = mac == null ? null : vantarisFabricanteMac(mac);
    final ttl = ping.isEmpty ? null : ping.first.$2;
    final c = vantarisClasificar(
      puertos: puertos,
      fabricante: fabricante,
      snmp: snmp.isNotEmpty ? snmp.first : null,
      modeloSnmp: hr.isNotEmpty ? hr.first : null,
      titulo: res[4] as String?,
      netbios: nb?.$1,
      ttl: ttl,
      puertaEnlace: ip == gw,
    );
    equipos.add({
      'ip': ip,
      'nombre': nb?.$1 ?? (snmp.length > 1 && snmp[1].isNotEmpty ? snmp[1] : null) ?? res[0],
      'mac': mac,
      'fabricante': fabricante,
      'tipo': c['tipo'],
      'modelo': c['modelo'],
      'so': c['so'],
      'puertos': puertos.toList()..sort(),
      if (ttl != null) 'ttl': ttl,
      if (ping.isNotEmpty) 'ms': ping.first.$1,
    });
  });
  int ipOrden(Map e) => _ipNum(e['ip'] as String) ?? 0;
  equipos.sort((a, b) => ipOrden(a).compareTo(ipOrden(b)));
  final impresoras = equipos.where((e) => e['tipo'] == 'impresora').length;
  return {
    'ok': true,
    'redes': [for (final r in lista) '$r.0/24'],
    'propias': propias.toList(),
    if (gw != null) 'puertaEnlace': gw,
    'equipos': equipos,
    'segundos': (sw.elapsedMilliseconds / 1000).round(),
    'mensaje': '${equipos.length} equipos en ${lista.map((r) => '$r.0/24').join(' y ')}'
        '${impresoras > 0 ? ' ($impresoras impresoras)' : ''}.',
  };
}

// ---------------------------------------------------------------- Windows: impresoras instaladas

List<Map<String, dynamic>> _listaWindows() {
  final out = <Map<String, dynamic>>[];
  final flags = w.PRINTER_ENUM_LOCAL | w.PRINTER_ENUM_CONNECTIONS;
  final need = calloc<Uint32>();
  final count = calloc<Uint32>();
  final defLen = calloc<Uint32>()..value = 512;
  final defBuf = w.wsalloc(512);
  Pointer<Uint8> buf = nullptr;
  try {
    w.EnumPrinters(flags, nullptr, 2, nullptr, 0, need, count);
    if (need.value == 0) return out;
    buf = calloc<Uint8>(need.value);
    if (w.EnumPrinters(flags, nullptr, 2, buf, need.value, need, count) == 0) return out;
    final pred = w.GetDefaultPrinter(defBuf, defLen) != 0 ? defBuf.toDartString() : '';
    final info = buf.cast<w.PRINTER_INFO_2>();
    for (var i = 0; i < count.value; i++) {
      final p = info[i];
      String s(Pointer<Utf16> x) => x == nullptr ? '' : x.toDartString();
      final nombre = s(p.pPrinterName);
      out.add({
        'n': i,
        'nombre': nombre,
        'puerto': s(p.pPortName),
        'driver': s(p.pDriverName),
        'predeterminada': nombre == pred,
      });
    }
  } finally {
    calloc.free(need);
    calloc.free(count);
    calloc.free(defLen);
    calloc.free(defBuf);
    if (buf != nullptr) calloc.free(buf);
  }
  return out;
}

Future<Map<String, dynamic>> _impresorasWindows() async {
  try {
    final l = _listaWindows();
    return {'ok': true, 'impresoras': l, 'mensaje': '${l.length} impresoras instaladas en Windows.'};
  } catch (e) {
    return {'ok': false, 'motivo': 'No se han podido leer las impresoras de Windows: $e'};
  }
}

Future<Map<String, dynamic>> _rawWindows(int n, bool cajon) async {
  final l = _listaWindows();
  if (n < 0 || n >= l.length) return {'ok': false, 'motivo': 'Esa impresora ya no está en el equipo.'};
  final nombre = l[n]['nombre'] as String;
  final datos = cajon
      ? [...vantarisPulsoCajon(0), ...vantarisPulsoCajon(1)]
      : vantarisTicketPrueba(destino: nombre);
  final pNombre = nombre.toNativeUtf16();
  final h = calloc<IntPtr>();
  final doc = calloc<w.DOC_INFO_1>();
  final pDoc = 'Vantaris Soporte'.toNativeUtf16();
  final pTipo = 'RAW'.toNativeUtf16();
  final pDatos = calloc<Uint8>(datos.length);
  final escritos = calloc<Uint32>();
  var abierta = false;
  try {
    if (w.OpenPrinter(pNombre, h, nullptr) == 0) {
      return {'ok': false, 'motivo': 'Windows no deja abrir «$nombre».'};
    }
    abierta = true;
    doc.ref
      ..pDocName = pDoc
      ..pOutputFile = nullptr
      ..pDatatype = pTipo;
    if (w.StartDocPrinter(h.value, 1, doc) == 0) {
      return {'ok': false, 'motivo': '«$nombre» no acepta trabajos en RAW (¿no es de tickets?).'};
    }
    w.StartPagePrinter(h.value);
    pDatos.asTypedList(datos.length).setAll(0, datos);
    final ok = w.WritePrinter(h.value, pDatos, datos.length, escritos) != 0;
    w.EndPagePrinter(h.value);
    w.EndDocPrinter(h.value);
    if (!ok) return {'ok': false, 'motivo': 'Fallo al enviar a «$nombre».'};
    return {
      'ok': true,
      'mensaje': cajon
          ? 'Pulso de apertura enviado al cajón por «$nombre».'
          : 'Ticket de prueba enviado a «$nombre» (cola de impresión de Windows).',
    };
  } finally {
    if (abierta) w.ClosePrinter(h.value);
    for (final p in [pNombre, pDoc, pTipo]) {
      calloc.free(p);
    }
    calloc.free(h);
    calloc.free(doc);
    calloc.free(pDatos);
    calloc.free(escritos);
  }
}
