// Vantaris Cobertura: informe PDF (sin librerías: texto Helvetica, rectángulos, líneas e imágenes
// comprimidas con zlib). Página 1 resumen + mapa principal, 2 recomendaciones, detalle por punto
// y un mapa por cada capa con datos.

import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Color, Colors;

import 'mapa.dart';
import 'modelo.dart';

const _marino = Color(0xFF0F1A30);
const _verde = Color(0xFF0A7B71);
const _gris = Color(0xFF475569);
const _linea = Color(0xFFE2E7EF);
const _negro = Color(0xFF111827);

String _num(double v) {
  final r = (v * 100).round();
  final neg = r < 0;
  final a = r.abs();
  final b = StringBuffer();
  if (neg && a != 0) b.write('-');
  b.write(a ~/ 100);
  final d = a % 100;
  if (d != 0) {
    var s = d.toString().padLeft(2, '0');
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    b.write('.$s');
  }
  return b.toString();
}

Uint8List _latin1(String s) => Uint8List.fromList([for (final c in s.codeUnits) c & 0xFF]);

String _cadena(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    int ch;
    if (r == 0x20AC) {
      ch = 0x80; // €
    } else if (r == 0x2014 || r == 0x2013) {
      ch = 0x2D; // — –
    } else if (r == 0x2018 || r == 0x2019) {
      ch = 0x27;
    } else if (r == 0x2026) {
      ch = 0x2E; // …
    } else if (r == 0x2265) {
      ch = 0x3E; // ≥
    } else if (r == 0x2264) {
      ch = 0x3C; // ≤
    } else if (r == 0x203A) {
      ch = 0x3E; // ›
    } else if ((r >= 32 && r <= 126) || (r >= 160 && r <= 255)) {
      ch = r;
    } else {
      ch = 0x3F;
    }
    if (ch == 0x28 || ch == 0x29 || ch == 0x5C) b.write('\\');
    b.writeCharCode(ch);
  }
  return b.toString();
}

const _anchos = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, //
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

double anchoTexto(String s, double tam, {bool negrita = false}) {
  var t = 0;
  for (final c in s.codeUnits) {
    t += (c >= 32 && c <= 126) ? _anchos[c - 32] : 556;
  }
  return t / 1000 * tam * (negrita ? 1.07 : 1);
}

List<String> partir(String t, double anchoMax, double tam, {bool negrita = false}) {
  final out = <String>[];
  for (final par in t.split('\n')) {
    var linea = '';
    for (final p in par.split(' ')) {
      final prueba = linea.isEmpty ? p : '$linea $p';
      if (anchoTexto(prueba, tam, negrita: negrita) > anchoMax && linea.isNotEmpty) {
        out.add(linea);
        linea = p;
      } else {
        linea = prueba;
      }
    }
    out.add(linea);
  }
  return out;
}

class Pdf {
  final _objetos = <Uint8List?>[];
  final _paginas = <int>[];
  late final int _idPaginas;

  Pdf() {
    _reservar();
    _idPaginas = _reservar();
    _poner(_reservar(), '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    _poner(_reservar(), '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
  }

  int _reservar() {
    _objetos.add(null);
    return _objetos.length;
  }

  void _poner(int id, String c) => _objetos[id - 1] = _latin1(c);

  Uint8List _flujo(String dic, List<int> datos) {
    final b = BytesBuilder(copy: false)
      ..add(_latin1('<< $dic /Length ${datos.length} >>\nstream\n'))
      ..add(datos)
      ..add(_latin1('\nendstream'));
    return b.takeBytes();
  }

  int _imagen(int w, int h, Uint8List rgba) {
    final rgb = Uint8List(w * h * 3);
    for (var i = 0, j = 0; i < w * h; i++, j += 4) {
      final a = rgba[j + 3];
      // Componer sobre blanco (el informe no necesita transparencia).
      int c(int v) => (v * a + 255 * (255 - a)) ~/ 255;
      rgb[i * 3] = c(rgba[j]);
      rgb[i * 3 + 1] = c(rgba[j + 1]);
      rgb[i * 3 + 2] = c(rgba[j + 2]);
    }
    final z = ZLibCodec(level: 6).encode(rgb);
    final id = _reservar();
    _objetos[id - 1] = _flujo(
        '/Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
        z);
    return id;
  }

  PaginaPdf pagina({double ancho = 595.28, double alto = 841.89}) => PaginaPdf._(this, ancho, alto);

  void _cerrar(PaginaPdf p) {
    final idC = _reservar();
    _objetos[idC - 1] = _flujo('', _latin1(p._contenido.toString()));
    final xo = p._imagenes.isEmpty ? '' : ' /XObject << ${p._imagenes.map((i) => '/Im$i $i 0 R').join(' ')} >>';
    final idP = _reservar();
    _poner(idP,
        '<< /Type /Page /Parent $_idPaginas 0 R /MediaBox [0 0 ${_num(p.ancho)} ${_num(p.alto)}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >>$xo >> /Contents $idC 0 R >>');
    _paginas.add(idP);
  }

  Uint8List bytes() {
    _poner(1, '<< /Type /Catalog /Pages $_idPaginas 0 R >>');
    _poner(_idPaginas, '<< /Type /Pages /Count ${_paginas.length} /Kids [${_paginas.map((p) => '$p 0 R').join(' ')}] >>');
    final out = BytesBuilder(copy: false);
    out.add(_latin1('%PDF-1.4\n%âãÏÓ\n'));
    final off = <int>[];
    for (var i = 0; i < _objetos.length; i++) {
      off.add(out.length);
      out.add(_latin1('${i + 1} 0 obj\n'));
      out.add(_objetos[i] ?? _latin1('null'));
      out.add(_latin1('\nendobj\n'));
    }
    final xref = out.length;
    final b = StringBuffer('xref\n0 ${_objetos.length + 1}\n0000000000 65535 f \n');
    for (final o in off) {
      b.write('${o.toString().padLeft(10, '0')} 00000 n \n');
    }
    b.write('trailer\n<< /Size ${_objetos.length + 1} /Root 1 0 R /Info << /Producer (Vantaris Soporte - Cobertura) >> >>\nstartxref\n$xref\n%%EOF\n');
    out.add(_latin1(b.toString()));
    return out.takeBytes();
  }
}

class PaginaPdf {
  final Pdf _pdf;
  final double ancho, alto;
  final _contenido = StringBuffer();
  final _imagenes = <int>[];

  PaginaPdf._(this._pdf, this.ancho, this.alto);

  String _rgb(Color c) => '${_num(c.red / 255)} ${_num(c.green / 255)} ${_num(c.blue / 255)}';

  /// Texto con la línea base en y (medido desde arriba).
  void texto(String t, double x, double y, double tam, {Color color = _negro, bool negrita = false}) {
    _contenido.write('${_rgb(color)} rg BT /${negrita ? 'F1' : 'F2'} ${_num(tam)} Tf ${_num(x)} ${_num(alto - y)} Td (${_cadena(t)}) Tj ET\n');
  }

  /// Texto partido en líneas que caben en [anchoMax]. Devuelve la y de la siguiente línea.
  double parrafo(String t, double x, double y, double anchoMax, double tam,
      {Color color = _negro, bool negrita = false, double interlinea = 1.35}) {
    var yy = y;
    for (final l in partir(t, anchoMax, tam, negrita: negrita)) {
      texto(l, x, yy, tam, color: color, negrita: negrita);
      yy += tam * interlinea;
    }
    return yy;
  }

  void rect(double x, double y, double w, double h, Color color) {
    _contenido.write('${_rgb(color)} rg ${_num(x)} ${_num(alto - y - h)} ${_num(w)} ${_num(h)} re f\n');
  }

  void linea(double x1, double y1, double x2, double y2, double grosor, Color color) {
    _contenido.write('${_rgb(color)} RG ${_num(grosor)} w ${_num(x1)} ${_num(alto - y1)} m ${_num(x2)} ${_num(alto - y2)} l S\n');
  }

  void imagen(int w, int h, Uint8List rgba, double x, double y, double ancho, double alto) {
    final id = _pdf._imagen(w, h, rgba);
    _imagenes.add(id);
    _contenido.write('q ${_num(ancho)} 0 0 ${_num(alto)} ${_num(x)} ${_num(this.alto - y - alto)} cm /Im$id Do Q\n');
  }

  void fin() => _pdf._cerrar(this);
}

Future<Uint8List> informePdf(Proyecto p, ui.Image? plano, List<RedWifi> redes) async {
  final pdf = Pdf();
  const m = 40.0;
  final capas = Capa.values.where((c) => p.mediciones.any((x) => c.valor(x) != null)).toList();
  final principal = capas.isEmpty ? Capa.wifi : capas.first;

  // ---- Página 1: resumen y mapa principal
  {
    final pg = pdf.pagina();
    pg.rect(0, 0, pg.ancho, 92, _marino);
    pg.texto('Informe de cobertura', m, 44, 22, color: Colors.white, negrita: true);
    pg.texto(p.nombre, m, 68, 12, color: const Color(0xFFB9C6E4));
    final f = fechaHora(DateTime.now().millisecondsSinceEpoch);
    pg.texto(f, pg.ancho - m - anchoTexto(f, 10), 68, 10, color: const Color(0xFFB9C6E4));
    var y = 118.0;
    pg.texto(
        '${p.mediciones.length} puntos medidos · local de ${fmt(p.anchoMetros, 1)} × ${fmt(p.altoMetros, 1)} m',
        m, y, 10,
        color: _gris);
    y += 18;
    final anchoMapa = pg.ancho - 2 * m;
    final altoMapa = math.min(anchoMapa * p.altoMetros / p.anchoMetros, 380.0);
    final anchoReal = altoMapa * p.anchoMetros / p.altoMetros;
    final img = await imagenMapa(p, plano, principal, 1400);
    pg.texto('Mapa: ${principal.nombre}', m, y + 4, 11, color: _marino, negrita: true);
    y += 12;
    pg.imagen(img.ancho, img.alto, img.rgba, m + (anchoMapa - anchoReal) / 2, y, anchoReal, altoMapa);
    y += altoMapa + 14;
    var lx = m;
    for (final n in Nivel.values) {
      pg.rect(lx, y - 8, 10, 10, colorNivel(n));
      pg.texto(n.nombre, lx + 14, y, 9, color: _gris);
      lx += 14 + anchoTexto(n.nombre, 9) + 18;
    }
    y += 22;
    pg.texto('Resumen', m, y, 13, color: _marino, negrita: true);
    y += 16;
    final cols = [m, m + 140, m + 220, m + 300, m + 380];
    const cab = ['Medida', 'Media', 'Peor', 'Mejor', 'Puntos buenos'];
    for (var i = 0; i < cab.length; i++) {
      pg.texto(cab[i], cols[i], y, 9, color: _gris, negrita: true);
    }
    y += 6;
    pg.linea(m, y, pg.ancho - m, y, 0.6, _linea);
    y += 14;
    for (final c in capas) {
      final r = Analisis.resumen(p, c);
      final buenos = (r.porNivel[Nivel.excelente] ?? 0) + (r.porNivel[Nivel.buena] ?? 0);
      pg.texto(c.nombre, cols[0], y, 10);
      pg.texto('${fmt(r.media, c.decimales)} ${c.unidad}', cols[1], y, 10);
      pg.texto('${fmt(r.peor, c.decimales)} ${c.unidad}${r.peorPunto != null ? '  (#${r.peorPunto})' : ''}', cols[2], y, 10);
      pg.texto('${fmt(r.mejor, c.decimales)} ${c.unidad}', cols[3], y, 10);
      pg.texto('$buenos de ${r.puntos}', cols[4], y, 10,
          color: buenos == r.puntos ? _verde : const Color(0xFFB45309), negrita: true);
      y += 16;
    }
    pg.fin();
  }

  // ---- Página 2: recomendaciones
  {
    final pg = pdf.pagina();
    var y = 56.0;
    pg.texto('Recomendaciones', m, y, 16, color: _marino, negrita: true);
    y += 22;
    for (final r in Analisis.recomendaciones(p, redes)) {
      pg.rect(m, y - 7, 4, 4, _verde);
      y = pg.parrafo(r, m + 12, y, pg.ancho - 2 * m - 12, 10.5) + 6;
    }
    final canal = Analisis.mejorCanalTexto(redes, Analisis.redPropia(p));
    if (canal != null) y = pg.parrafo(canal, m, y + 4, pg.ancho - 2 * m, 10, color: _gris) + 6;
    pg.texto('Generado con Vantaris Soporte. Umbrales WiFi: excelente ≥ -55 dBm, buena ≥ -67, regular ≥ -75.', m,
        pg.alto - 28, 8,
        color: _gris);
    pg.fin();
  }

  // ---- Detalle por punto (las páginas que hagan falta)
  const filasPorPagina = 40;
  for (var ini = 0, hoja = 0; ini < p.mediciones.length; ini += filasPorPagina, hoja++) {
    final pg = pdf.pagina();
    var y = 56.0;
    pg.texto(hoja == 0 ? 'Detalle por punto' : 'Detalle por punto (sigue)', m, y, 13, color: _marino, negrita: true);
    y += 16;
    final cx = [m, m + 26, m + 150, m + 215, m + 285, m + 350, m + 420];
    const cab = ['#', 'WiFi', 'Señal', 'Móvil', 'Router', 'Internet', 'Pérdida / vel.'];
    for (var i = 0; i < cab.length; i++) {
      pg.texto(cab[i], cx[i], y, 8.5, color: _gris, negrita: true);
    }
    y += 5;
    pg.linea(m, y, pg.ancho - m, y, 0.6, _linea);
    y += 12;
    for (var i = ini; i < math.min(ini + filasPorPagina, p.mediciones.length); i++) {
      final me = p.mediciones[i];
      final w = me.wifi;
      pg.texto('${i + 1}', cx[0], y, 9, negrita: true);
      final ssid = (w?.ssid ?? '—');
      pg.texto('${ssid.length > 22 ? ssid.substring(0, 22) : ssid}${w?.canal != null ? ' · c${w!.canal}' : ''}', cx[1], y, 9);
      pg.texto(w?.rssi != null ? '${w!.rssi} dBm' : '—', cx[2], y, 9,
          color: w?.rssi != null ? colorNivel(Capa.wifi.nivel(w!.rssi!.toDouble())) : _gris, negrita: true);
      final mo = me.movil;
      final movTxt = [if (mo?.tipo != null) mo!.tipo!, if (mo?.dbm != null) '${mo!.dbm} dBm'].join(' ');
      pg.texto(movTxt.isEmpty ? '—' : movTxt, cx[3], y, 9);
      pg.texto(me.pingRouter?.mediaMs != null ? '${fmt(me.pingRouter!.mediaMs)} ms' : '—', cx[4], y, 9);
      pg.texto(me.pingInternet?.mediaMs != null ? '${fmt(me.pingInternet!.mediaMs)} ms' : '—', cx[5], y, 9);
      final perd = (me.pingInternet ?? me.pingRouter)?.perdida;
      final pv = [if (perd != null) '${fmt(perd)} %', if (me.velocidadMbps != null) '${fmt(me.velocidadMbps, 1)} Mbps'].join(' · ');
      pg.texto(pv.isEmpty ? '—' : pv, cx[6], y, 9);
      y += 14;
      if (me.nota.trim().isNotEmpty) {
        final n = me.nota.trim();
        pg.texto(n.length > 90 ? n.substring(0, 90) : n, cx[1], y - 3, 8, color: _gris);
        y += 10;
      }
    }
    pg.fin();
  }

  // ---- Una página por cada capa extra con su mapa
  for (final c in capas.skip(1)) {
    final pg = pdf.pagina();
    pg.texto('Mapa: ${c.nombre}', m, 56, 16, color: _marino, negrita: true);
    final anchoMapa = pg.ancho - 2 * m;
    final altoMapa = math.min(anchoMapa * p.altoMetros / p.anchoMetros, pg.alto - 160);
    final anchoReal = altoMapa * p.anchoMetros / p.altoMetros;
    final img = await imagenMapa(p, plano, c, 1400);
    pg.imagen(img.ancho, img.alto, img.rgba, m + (anchoMapa - anchoReal) / 2, 74, anchoReal, altoMapa);
    pg.fin();
  }
  return pdf.bytes();
}
