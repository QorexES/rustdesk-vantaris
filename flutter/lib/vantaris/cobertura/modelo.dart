// Vantaris Cobertura: modelo de datos, umbrales y análisis (recomendaciones, canales).
//
// Venía de la app suelta VantarisCobertura (KMP, archivada el 03-11-2026); aquí vive dentro de
// Vantaris Soporte para no tener una app más. El proyecto se guarda en JSON con los mismos campos
// que aquella, así que los .json de una se abren en la otra.

import 'dart:convert';
import 'dart:math' as math;

const kHostInternet = '1.1.1.1';

class LecturaWifi {
  final String? ssid;
  final String? bssid;

  /// dBm (negativo).
  final int? rssi;
  final int? frecuenciaMhz;
  final int? canal;
  final double? velocidadMbps;
  final String? estandar;

  const LecturaWifi({
    this.ssid,
    this.bssid,
    this.rssi,
    this.frecuenciaMhz,
    this.canal,
    this.velocidadMbps,
    this.estandar,
  });

  LecturaWifi conRssi(int? r) => LecturaWifi(
      ssid: ssid,
      bssid: bssid,
      rssi: r,
      frecuenciaMhz: frecuenciaMhz,
      canal: canal,
      velocidadMbps: velocidadMbps,
      estandar: estandar);

  Map<String, dynamic> toJson() => {
        'ssid': ssid,
        'bssid': bssid,
        'rssi': rssi,
        'frecuenciaMhz': frecuenciaMhz,
        'canal': canal,
        'velocidadMbps': velocidadMbps,
        'estandar': estandar,
      };

  static LecturaWifi? fromJson(dynamic j) => j is Map
      ? LecturaWifi(
          ssid: j['ssid'] as String?,
          bssid: j['bssid'] as String?,
          rssi: _int(j['rssi']),
          frecuenciaMhz: _int(j['frecuenciaMhz']),
          canal: _int(j['canal']),
          velocidadMbps: _dbl(j['velocidadMbps']),
          estandar: j['estandar'] as String?,
        )
      : null;
}

class LecturaMovil {
  /// 2G, 3G, 4G, 5G…
  final String? tipo;
  final int? dbm;

  /// 0..4 según Android.
  final int? nivel;
  final String? operador;

  const LecturaMovil({this.tipo, this.dbm, this.nivel, this.operador});

  Map<String, dynamic> toJson() =>
      {'tipo': tipo, 'dbm': dbm, 'nivel': nivel, 'operador': operador};

  static LecturaMovil? fromJson(dynamic j) => j is Map
      ? LecturaMovil(
          tipo: j['tipo'] as String?,
          dbm: _int(j['dbm']),
          nivel: _int(j['nivel']),
          operador: j['operador'] as String?,
        )
      : null;
}

class ResultadoPing {
  final String host;
  final int enviados;
  final int recibidos;
  final double? minMs, mediaMs, maxMs, jitterMs;

  const ResultadoPing(this.host, this.enviados, this.recibidos,
      {this.minMs, this.mediaMs, this.maxMs, this.jitterMs});

  double get perdida => enviados == 0 ? 0 : (enviados - recibidos) * 100.0 / enviados;

  Map<String, dynamic> toJson() => {
        'host': host,
        'enviados': enviados,
        'recibidos': recibidos,
        'minMs': minMs,
        'mediaMs': mediaMs,
        'maxMs': maxMs,
        'jitterMs': jitterMs,
      };

  static ResultadoPing? fromJson(dynamic j) => j is Map
      ? ResultadoPing(j['host'] as String? ?? '', _int(j['enviados']) ?? 0, _int(j['recibidos']) ?? 0,
          minMs: _dbl(j['minMs']),
          mediaMs: _dbl(j['mediaMs']),
          maxMs: _dbl(j['maxMs']),
          jitterMs: _dbl(j['jitterMs']))
      : null;
}

ResultadoPing resumirPing(String host, int enviados, List<double> tiempos) {
  if (tiempos.isEmpty) return ResultadoPing(host, enviados, 0);
  double jitter = 0;
  if (tiempos.length >= 2) {
    double s = 0;
    for (var i = 1; i < tiempos.length; i++) {
      s += (tiempos[i] - tiempos[i - 1]).abs();
    }
    jitter = s / (tiempos.length - 1);
  }
  final media = tiempos.reduce((a, b) => a + b) / tiempos.length;
  return ResultadoPing(host, enviados, tiempos.length,
      minMs: tiempos.reduce(math.min),
      mediaMs: media,
      maxMs: tiempos.reduce(math.max),
      jitterMs: jitter);
}

class RedWifi {
  final String ssid;
  final String bssid;
  final int rssi;
  final int? frecuenciaMhz;
  final int? canal;

  const RedWifi(this.ssid, this.bssid, this.rssi, this.frecuenciaMhz, this.canal);

  String get banda {
    final f = frecuenciaMhz ?? 0;
    final c = canal ?? 0;
    if (f >= 5925) return '6 GHz';
    if (f >= 4900) return '5 GHz';
    if (f >= 2400 && f <= 2500) return '2,4 GHz';
    if (c >= 1 && c <= 14) return '2,4 GHz';
    if (c > 14) return '5 GHz';
    return '?';
  }

  static RedWifi? fromJson(dynamic j) => j is Map
      ? RedWifi(j['ssid'] as String? ?? '(oculta)', j['bssid'] as String? ?? '',
          _int(j['rssi']) ?? -100, _int(j['frecuenciaMhz']), _int(j['canal']))
      : null;
}

/// Una medición en un punto del plano. x, y en 0..1 (fracción del ancho/alto del plano).
class Medicion {
  final int id;
  final double x, y;
  final int instante;
  final LecturaWifi? wifi;
  final LecturaMovil? movil;
  final ResultadoPing? pingRouter;
  final ResultadoPing? pingInternet;
  final double? velocidadMbps;
  final String nota;

  const Medicion({
    required this.id,
    required this.x,
    required this.y,
    required this.instante,
    this.wifi,
    this.movil,
    this.pingRouter,
    this.pingInternet,
    this.velocidadMbps,
    this.nota = '',
  });

  Medicion conNota(String n) => Medicion(
      id: id,
      x: x,
      y: y,
      instante: instante,
      wifi: wifi,
      movil: movil,
      pingRouter: pingRouter,
      pingInternet: pingInternet,
      velocidadMbps: velocidadMbps,
      nota: n);

  Medicion movida(double nx, double ny) => Medicion(
      id: id,
      x: nx,
      y: ny,
      instante: instante,
      wifi: wifi,
      movil: movil,
      pingRouter: pingRouter,
      pingInternet: pingInternet,
      velocidadMbps: velocidadMbps,
      nota: nota);

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'instante': instante,
        'wifi': wifi?.toJson(),
        'movil': movil?.toJson(),
        'pingRouter': pingRouter?.toJson(),
        'pingInternet': pingInternet?.toJson(),
        'velocidadMbps': velocidadMbps,
        'nota': nota,
      };

  static Medicion fromJson(Map j) => Medicion(
        id: _int(j['id']) ?? 0,
        x: _dbl(j['x']) ?? 0.5,
        y: _dbl(j['y']) ?? 0.5,
        instante: _int(j['instante']) ?? 0,
        wifi: LecturaWifi.fromJson(j['wifi']),
        movil: LecturaMovil.fromJson(j['movil']),
        pingRouter: ResultadoPing.fromJson(j['pingRouter']),
        pingInternet: ResultadoPing.fromJson(j['pingInternet']),
        velocidadMbps: _dbl(j['velocidadMbps']),
        nota: j['nota'] as String? ?? '',
      );
}

class Proyecto {
  final String nombre;

  /// PNG/JPG del plano en base64, o null para plano en blanco.
  final String? planoBase64;

  /// Medidas reales del local (para la cuadrícula y la escala).
  final double anchoMetros;
  final double altoMetros;
  final List<Medicion> mediciones;
  final int version;

  const Proyecto({
    this.nombre = 'Local sin nombre',
    this.planoBase64,
    this.anchoMetros = 20,
    this.altoMetros = 12,
    this.mediciones = const [],
    this.version = 1,
  });

  Proyecto copia({
    String? nombre,
    String? planoBase64,
    bool quitarPlano = false,
    double? anchoMetros,
    double? altoMetros,
    List<Medicion>? mediciones,
  }) =>
      Proyecto(
        nombre: nombre ?? this.nombre,
        planoBase64: quitarPlano ? null : (planoBase64 ?? this.planoBase64),
        anchoMetros: anchoMetros ?? this.anchoMetros,
        altoMetros: altoMetros ?? this.altoMetros,
        mediciones: mediciones ?? this.mediciones,
        version: version,
      );

  Map<String, dynamic> toJson() => {
        'nombre': nombre,
        'planoBase64': planoBase64,
        'anchoMetros': anchoMetros,
        'altoMetros': altoMetros,
        'mediciones': mediciones.map((m) => m.toJson()).toList(),
        'version': version,
      };

  String aJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  static Proyecto deJson(String s) {
    final j = jsonDecode(s) as Map;
    return Proyecto(
      nombre: j['nombre'] as String? ?? 'Local sin nombre',
      planoBase64: j['planoBase64'] as String?,
      anchoMetros: _dbl(j['anchoMetros']) ?? 20,
      altoMetros: _dbl(j['altoMetros']) ?? 12,
      mediciones: [
        for (final m in (j['mediciones'] as List? ?? const []))
          if (m is Map) Medicion.fromJson(m)
      ],
      version: _int(j['version']) ?? 1,
    );
  }
}

/// Qué se pinta en el mapa de calor.
enum Capa {
  wifi('Señal WiFi', 'dBm'),
  movil('Señal móvil', 'dBm'),
  latencia('Latencia', 'ms'),
  perdida('Paquetes perdidos', '%'),
  velocidad('Velocidad', 'Mbps');

  final String nombre;
  final String unidad;
  const Capa(this.nombre, this.unidad);

  double? valor(Medicion m) {
    switch (this) {
      case Capa.wifi:
        return m.wifi?.rssi?.toDouble();
      case Capa.movil:
        return m.movil?.dbm?.toDouble();
      case Capa.latencia:
        return m.pingInternet?.mediaMs ?? m.pingRouter?.mediaMs;
      case Capa.perdida:
        return (m.pingInternet ?? m.pingRouter)?.perdida;
      case Capa.velocidad:
        return m.velocidadMbps;
    }
  }

  /// Calidad 0..1 (0 = mala, 1 = excelente). Umbrales pensados para TPV, comanderas y datáfonos.
  double calidad(double v) {
    switch (this) {
      case Capa.wifi:
        return _tramo(v, -85, -50);
      case Capa.movil:
        return _tramo(v, -120, -85);
      case Capa.latencia:
        return 1 - _tramo(v, 20, 200);
      case Capa.perdida:
        return 1 - _tramo(v, 0, 7);
      case Capa.velocidad:
        return _tramo(v, 0.5, 30);
    }
  }

  Nivel nivel(double v) => Nivel.de(calidad(v));

  int get decimales => this == Capa.velocidad ? 1 : 0;

  static double _tramo(double v, double malo, double bueno) =>
      ((v - malo) / (bueno - malo)).clamp(0.0, 1.0).toDouble();
}

enum Nivel {
  excelente('Excelente', 'Perfecto para TPV, comanderas y videollamadas'),
  buena('Buena', 'Va bien para TPV y comanderas'),
  regular('Regular', 'Puede haber cortes: mejor no poner aquí un TPV fijo'),
  mala('Mala', 'Hace falta un repetidor o un punto de acceso cerca');

  final String nombre;
  final String consejo;
  const Nivel(this.nombre, this.consejo);

  static Nivel de(double calidad) {
    if (calidad >= 0.75) return Nivel.excelente;
    if (calidad >= 0.5) return Nivel.buena;
    if (calidad >= 0.28) return Nivel.regular;
    return Nivel.mala;
  }
}

int? canalDeFrecuencia(int? mhz) {
  if (mhz == null) return null;
  if (mhz == 2484) return 14;
  if (mhz >= 2412 && mhz <= 2472) return (mhz - 2407) ~/ 5;
  if (mhz >= 5000 && mhz <= 5900) return (mhz - 5000) ~/ 5;
  if (mhz >= 5925 && mhz <= 7125) return (mhz - 5950) ~/ 5;
  return null;
}

/// Número con coma decimal y [dec] decimales; «—» si no hay dato.
String fmt(double? v, [int dec = 0]) {
  if (v == null || v.isNaN || v.isInfinite) return '—';
  final s = v.toStringAsFixed(dec);
  final r = dec == 0 ? s : s.replaceAll('.', ',');
  return r == '-0' ? '0' : r;
}

String fechaHora(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(d.day)}/${dos(d.month)}/${d.year} ${dos(d.hour)}:${dos(d.minute)}';
}

int? _int(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
double? _dbl(dynamic v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

class ResumenCapa {
  final Capa capa;
  final int puntos;
  final double? media, peor, mejor;
  final Map<Nivel, int> porNivel;

  /// Número (1..n) del peor punto.
  final int? peorPunto;

  const ResumenCapa(this.capa, this.puntos, this.media, this.peor, this.mejor, this.porNivel, this.peorPunto);
}

class Analisis {
  static ResumenCapa resumen(Proyecto p, Capa capa) {
    final vals = <MapEntry<int, double>>[];
    for (var i = 0; i < p.mediciones.length; i++) {
      final v = capa.valor(p.mediciones[i]);
      if (v != null) vals.add(MapEntry(i + 1, v));
    }
    if (vals.isEmpty) return ResumenCapa(capa, 0, null, null, null, const {}, null);
    final porNivel = <Nivel, int>{};
    for (final e in vals) {
      final n = capa.nivel(e.value);
      porNivel[n] = (porNivel[n] ?? 0) + 1;
    }
    var peor = vals.first, mejor = vals.first;
    for (final e in vals) {
      if (capa.calidad(e.value) < capa.calidad(peor.value)) peor = e;
      if (capa.calidad(e.value) > capa.calidad(mejor.value)) mejor = e;
    }
    final media = vals.map((e) => e.value).reduce((a, b) => a + b) / vals.length;
    return ResumenCapa(capa, vals.length, media, peor.value, mejor.value, porNivel, peor.key);
  }

  static double _potencia(int rssi) => math.pow(10, (rssi + 100) / 20.0).toDouble();

  /// Ocupación de cada canal de 2,4 GHz (1..13): suma de la potencia de las redes que lo pisan.
  static List<double> ocupacion24(List<RedWifi> redes) {
    final occ = List<double>.filled(14, 0);
    for (final r in redes) {
      final c = r.canal;
      if (c == null || c < 1 || c > 14) continue;
      final pot = _potencia(r.rssi);
      for (var k = 1; k <= 13; k++) {
        final d = (k - c).abs();
        if (d <= 4) occ[k] += pot * (1 - d / 5.0);
      }
    }
    return occ;
  }

  /// Mejor canal de 2,4 GHz entre 1, 6 y 11. [propia] = SSID del local: no cuenta como competencia.
  static int? mejorCanal24(List<RedWifi> redes, [String? propia]) {
    final ajenas = redes.where((r) => r.ssid != propia).toList();
    if (!ajenas.any((r) => (r.canal ?? 0) >= 1 && (r.canal ?? 0) <= 14)) return null;
    final occ = ocupacion24(ajenas);
    return [1, 6, 11].reduce((a, b) => occ[b] < occ[a] ? b : a);
  }

  static int? mejorCanal5(List<RedWifi> redes, [String? propia]) {
    final en5 = redes
        .where((r) => r.ssid != propia && (r.canal ?? 0) > 14 && (r.frecuenciaMhz ?? 5000) < 5925)
        .toList();
    if (en5.isEmpty) return null;
    double ocup(int c) => en5
        .where((r) => ((r.canal ?? 0) - c).abs() < 4)
        .fold(0.0, (s, r) => s + _potencia(r.rssi));
    return [36, 40, 44, 48, 149, 153, 157, 161].reduce((a, b) => ocup(b) < ocup(a) ? b : a);
  }

  /// SSID más repetido en las mediciones = la red del local.
  static String? redPropia(Proyecto p) {
    final c = <String, int>{};
    for (final m in p.mediciones) {
      final s = m.wifi?.ssid;
      if (s != null) c[s] = (c[s] ?? 0) + 1;
    }
    if (c.isEmpty) return null;
    return c.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  static String _puntos(int n) => n == 1 ? 'punto' : 'puntos';

  static String _lista(List<int> idx, Proyecto p) => idx.map((i) {
        final nota = p.mediciones[i].nota.trim();
        return '#${i + 1}${nota.isNotEmpty ? ' $nota' : ''}';
      }).join(', ');

  static List<String> recomendaciones(Proyecto p, List<RedWifi> redes) {
    final out = <String>[];
    final ms = p.mediciones;
    if (ms.isEmpty) {
      return ['Aún no hay mediciones. Ve al mapa y toca los puntos del local donde quieras medir.'];
    }
    final wifi = resumen(p, Capa.wifi);
    if (wifi.puntos > 0) {
      final malos = <int>[], regulares = <int>[];
      for (var i = 0; i < ms.length; i++) {
        final r = ms[i].wifi?.rssi;
        if (r == null) continue;
        final n = Capa.wifi.nivel(r.toDouble());
        if (n == Nivel.mala) malos.add(i);
        if (n == Nivel.regular) regulares.add(i);
      }
      if (malos.isNotEmpty) {
        out.add('WiFi mala en ${malos.length} ${_puntos(malos.length)} (${_lista(malos, p)}). '
            'Pon un punto de acceso o un repetidor cerca, o lleva cable a esa zona antes de instalar un TPV o un datáfono WiFi.');
      } else if (regulares.isNotEmpty) {
        out.add('WiFi justa en ${regulares.length} ${_puntos(regulares.length)} (${_lista(regulares, p)}). '
            'Las comanderas pueden ir lentas ahí: valora un repetidor.');
      } else {
        out.add('La WiFi llega bien a todo lo medido (media ${fmt(wifi.media)} dBm). Sirve para TPV, comanderas y pantallas de cocina.');
      }
      final bssids = ms.map((m) => m.wifi?.bssid).whereType<String>().toSet();
      if (bssids.length > 1) {
        out.add('Se han visto ${bssids.length} puntos de acceso distintos de la misma red: la itinerancia funciona.');
      }
      final en24 = ms.where((m) {
        final f = m.wifi?.frecuenciaMhz ?? 0;
        return f >= 2400 && f <= 2500;
      }).length;
      if (en24 > ms.length / 2 && en24 > 0) {
        out.add('La mayoría de mediciones van por 2,4 GHz. Si el router tiene 5 GHz, los equipos cercanos irán más rápidos en esa banda (2,4 GHz llega más lejos, pero se satura).');
      }
    } else {
      out.add('No se pudo leer la WiFi en ninguna medición. Revisa que el equipo esté conectado a la WiFi del local y que la app tenga permiso de ubicación.');
    }
    final lat = resumen(p, Capa.latencia);
    if (lat.puntos > 0 && (lat.media ?? 0) > 100) {
      out.add('Latencia alta hacia internet (media ${fmt(lat.media)} ms). Puede ser la línea del local o el router saturado: prueba a reiniciarlo o habla con la operadora.');
    }
    final perd = resumen(p, Capa.perdida);
    final conPerdida = <int>[];
    for (var i = 0; i < ms.length; i++) {
      if (((ms[i].pingInternet ?? ms[i].pingRouter)?.perdida ?? 0) >= 5) conPerdida.add(i);
    }
    if (conPerdida.isNotEmpty) {
      out.add('Se pierden paquetes en ${conPerdida.length} ${_puntos(conPerdida.length)} '
          '(${conPerdida.map((i) => '#${i + 1}').join(', ')}). Con pérdidas, los cobros con datáfono pueden fallar.');
    } else if (perd.puntos > 0) {
      out.add('Sin pérdida de paquetes relevante.');
    }
    final router = ms.map((m) => m.pingRouter?.mediaMs).whereType<double>().toList();
    if (router.isNotEmpty) {
      final media = router.reduce((a, b) => a + b) / router.length;
      if (media > 30) {
        out.add('El router tarda en contestar (${fmt(media)} ms de media dentro del local): señal débil o router sobrecargado.');
      }
    }
    final movil = resumen(p, Capa.movil);
    if (movil.puntos > 0) {
      final malos = movil.porNivel[Nivel.mala] ?? 0;
      out.add(malos > 0
          ? 'Cobertura móvil mala en $malos ${_puntos(malos)}: si el datáfono o la comandera van por 4G, conéctalos a la WiFi en esas zonas.'
          : 'Cobertura móvil correcta (media ${fmt(movil.media)} dBm): el 4G sirve de respaldo si se cae la línea.');
    }
    final vel = resumen(p, Capa.velocidad);
    if (vel.puntos > 0 && (vel.media ?? 0) < 5) {
      out.add('Velocidad baja (${fmt(vel.media, 1)} Mbps de media). Para TPV basta, pero la carta digital y las fotos irán lentas.');
    }
    final c = mejorCanal24(redes, redPropia(p));
    if (c != null) {
      int? actual;
      for (final m in ms.reversed) {
        final k = m.wifi?.canal ?? 0;
        if (k >= 1 && k <= 14) {
          actual = k;
          break;
        }
      }
      if (actual != null && actual != c && (actual - c).abs() >= 3) {
        out.add('El canal 2,4 GHz del local es el $actual, pero el $c está más libre según las redes de alrededor. Cambiarlo en el router suele mejorar la estabilidad.');
      }
    }
    return out;
  }

  static String? mejorCanalTexto(List<RedWifi> redes, [String? propia]) {
    final c24 = mejorCanal24(redes, propia);
    final c5 = mejorCanal5(redes, propia);
    if (c24 == null && c5 == null) return null;
    final partes = [if (c24 != null) '$c24 en 2,4 GHz', if (c5 != null) '$c5 en 5 GHz'];
    return 'Según las ${redes.length} redes vistas alrededor, los canales más libres son: ${partes.join(' y ')}.';
  }
}

String csvProyecto(Proyecto p) {
  final b = StringBuffer(
      'punto;x_m;y_m;fecha;ssid;bssid;rssi_dbm;canal;frecuencia_mhz;enlace_mbps;movil_tipo;movil_dbm;operador;router_ms;internet_ms;jitter_ms;perdida_pct;velocidad_mbps;nota\n');
  for (var i = 0; i < p.mediciones.length; i++) {
    final m = p.mediciones[i];
    final w = m.wifi, mo = m.movil, pi = m.pingInternet;
    final celdas = [
      '${i + 1}',
      fmt(m.x * p.anchoMetros, 2),
      fmt(m.y * p.altoMetros, 2),
      fechaHora(m.instante),
      w?.ssid ?? '',
      w?.bssid ?? '',
      w?.rssi?.toString() ?? '',
      w?.canal?.toString() ?? '',
      w?.frecuenciaMhz?.toString() ?? '',
      w?.velocidadMbps != null ? fmt(w!.velocidadMbps, 1) : '',
      mo?.tipo ?? '',
      mo?.dbm?.toString() ?? '',
      mo?.operador ?? '',
      m.pingRouter?.mediaMs != null ? fmt(m.pingRouter!.mediaMs, 1) : '',
      pi?.mediaMs != null ? fmt(pi!.mediaMs, 1) : '',
      pi?.jitterMs != null ? fmt(pi!.jitterMs, 1) : '',
      pi != null ? fmt(pi.perdida) : '',
      m.velocidadMbps != null ? fmt(m.velocidadMbps, 1) : '',
      m.nota,
    ];
    b.writeln(celdas
        .map((c) => (c.contains(';') || c.contains('"')) ? '"${c.replaceAll('"', '""')}"' : c)
        .join(';'));
  }
  return b.toString();
}
