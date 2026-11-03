// Vantaris Cobertura: mapa de calor (IDW) y dibujo del plano con los puntos medidos.
// Lo usan la pantalla (CustomPainter) y el informe PDF (rasterizado con PictureRecorder).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'modelo.dart';

/// Escala de color de la calidad: rojo (mala) → naranja → amarillo → verde (excelente).
const _paradas = <MapEntry<double, Color>>[
  MapEntry(0.0, Color(0xFFDC2626)),
  MapEntry(0.28, Color(0xFFF97316)),
  MapEntry(0.5, Color(0xFFFACC15)),
  MapEntry(0.75, Color(0xFF4ADE80)),
  MapEntry(1.0, Color(0xFF16A34A)),
];

Color colorCalidad(double q) {
  final v = q.clamp(0.0, 1.0);
  for (var i = 0; i < _paradas.length - 1; i++) {
    final a = _paradas[i], b = _paradas[i + 1];
    if (v <= b.key) return Color.lerp(a.value, b.value, (v - a.key) / (b.key - a.key))!;
  }
  return _paradas.last.value;
}

Color colorNivel(Nivel n) {
  switch (n) {
    case Nivel.excelente:
      return const Color(0xFF16A34A);
    case Nivel.buena:
      return const Color(0xFF65A30D);
    case Nivel.regular:
      return const Color(0xFFF59E0B);
    case Nivel.mala:
      return const Color(0xFFDC2626);
  }
}

/// Mapa de calor interpolado (IDW) en una rejilla pequeña; se estira con filtrado al pintarlo.
Future<ui.Image?> mapaCalor(List<Medicion> mediciones, Capa capa, double anchoM, double altoM,
    double opacidad, {int columnas = 120}) {
  final pts = <List<double>>[];
  for (final m in mediciones) {
    final v = capa.valor(m);
    if (v != null) pts.add([m.x * anchoM, m.y * altoM, capa.calidad(v)]);
  }
  if (pts.isEmpty) return Future.value(null);
  final cols = columnas;
  final filas = math.max(1, (cols * altoM / anchoM).round());
  // Radio de influencia: se apaga lejos de los puntos medidos para no inventar.
  final diag = math.sqrt(anchoM * anchoM + altoM * altoM);
  final radio = math.max(2.5, diag * 0.16) * (pts.length <= 2 ? 1.4 : 1.0);
  final celdaW = anchoM / cols, celdaH = altoM / filas;
  final px = Uint8List(cols * filas * 4);
  for (var fy = 0; fy < filas; fy++) {
    for (var fx = 0; fx < cols; fx++) {
      final x = (fx + 0.5) * celdaW, y = (fy + 0.5) * celdaH;
      double num = 0, den = 0, dmin = double.maxFinite;
      for (final p in pts) {
        final dx = x - p[0], dy = y - p[1];
        final d2 = dx * dx + dy * dy;
        final d = math.sqrt(d2);
        if (d < dmin) dmin = d;
        final w = 1.0 / (d2 + 0.15); // ~ 1/d², suavizado para no dividir por cero
        num += w * p[2];
        den += w;
      }
      final alfa = (1 - ((dmin - radio * 0.55) / (radio * 0.9))).clamp(0.0, 1.0) * opacidad;
      if (alfa <= 0.01) continue;
      final c = colorCalidad(num / den);
      final o = (fy * cols + fx) * 4;
      // decodeImageFromPixels trata los píxeles como premultiplicados: sin multiplicar por el alfa,
      // los bordes del calor salían aclarados (halo azulado sobre blanco).
      final a = (alfa * 255).round();
      px[o] = c.red * a ~/ 255;
      px[o + 1] = c.green * a ~/ 255;
      px[o + 2] = c.blue * a ~/ 255;
      px[o + 3] = a;
    }
  }
  final hecho = Completer<ui.Image?>();
  ui.decodeImageFromPixels(px, cols, filas, ui.PixelFormat.rgba8888, (img) => hecho.complete(img));
  return hecho.future;
}

/// Caja de proporción [anchoM]:[altoM] centrada dentro de [tam].
Rect encajar(Size tam, double anchoM, double altoM, {double margen = 0}) {
  final aw = tam.width - 2 * margen, ah = tam.height - 2 * margen;
  final s = math.min(aw / anchoM, ah / altoM);
  final bw = anchoM * s, bh = altoM * s;
  return Rect.fromLTWH((tam.width - bw) / 2, (tam.height - bh) / 2, bw, bh);
}

/// Pinta plano (o cuadrícula de 1 m) + mapa de calor + puntos numerados dentro de [caja].
void dibujarMapa(
  Canvas canvas,
  Rect caja, {
  required ui.Image? plano,
  required double anchoM,
  required double altoM,
  required ui.Image? calor,
  required List<Medicion> mediciones,
  required Capa capa,
  int? seleccion,
  double escalaPuntos = 1,
  bool oscuro = false,
}) {
  canvas.drawRect(caja, Paint()..color = oscuro ? const Color(0xFF162033) : Colors.white);
  if (plano != null) {
    canvas.drawImageRect(
        plano,
        Rect.fromLTWH(0, 0, plano.width.toDouble(), plano.height.toDouble()),
        caja,
        Paint()..filterQuality = FilterQuality.medium);
  } else {
    final linea = Paint()..color = oscuro ? const Color(0xFF2A3854) : const Color(0xFFE3E8F0);
    final fuerte = Paint()..color = oscuro ? const Color(0xFF3A4A6A) : const Color(0xFFC9D2E0);
    final pasoX = caja.width / anchoM, pasoY = caja.height / altoM;
    for (var i = 0; i <= anchoM.ceil(); i++) {
      final x = caja.left + i * pasoX;
      if (x > caja.right + 0.5) break;
      final p = (i % 5 == 0 ? fuerte : linea)..strokeWidth = i % 5 == 0 ? 1.5 : 1;
      canvas.drawLine(Offset(x, caja.top), Offset(x, caja.bottom), p);
    }
    for (var i = 0; i <= altoM.ceil(); i++) {
      final y = caja.top + i * pasoY;
      if (y > caja.bottom + 0.5) break;
      final p = (i % 5 == 0 ? fuerte : linea)..strokeWidth = i % 5 == 0 ? 1.5 : 1;
      canvas.drawLine(Offset(caja.left, y), Offset(caja.right, y), p);
    }
  }
  if (calor != null) {
    canvas.drawImageRect(calor, Rect.fromLTWH(0, 0, calor.width.toDouble(), calor.height.toDouble()),
        caja, Paint()..filterQuality = FilterQuality.high);
  }
  canvas.drawRect(
      caja,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = oscuro ? const Color(0xFF3A4A6A) : const Color(0xFFB8C2D3));

  final r = 13.0 * escalaPuntos;
  for (var i = 0; i < mediciones.length; i++) {
    final m = mediciones[i];
    final c = Offset(caja.left + m.x * caja.width, caja.top + m.y * caja.height);
    final v = capa.valor(m);
    final color = v == null ? const Color(0xFF94A3B8) : colorCalidad(capa.calidad(v));
    if (m.id == seleccion) {
      canvas.drawCircle(
          c,
          r * 1.65,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * escalaPuntos
            ..color = oscuro ? Colors.white : const Color(0xFF0F1A30));
    }
    canvas.drawCircle(c, r + 2.5 * escalaPuntos, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = color);
    final tp = TextPainter(
      text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(color: Colors.white, fontSize: r * 0.95, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }
}

/// Rasteriza el mapa a [anchoPx] (para el PDF). Devuelve RGBA sin premultiplicar.
Future<({int ancho, int alto, Uint8List rgba})> imagenMapa(
    Proyecto p, ui.Image? plano, Capa capa, int anchoPx) async {
  final altoPx = math.max(1, (anchoPx * p.altoMetros / p.anchoMetros).round());
  final calor = await mapaCalor(p.mediciones, capa, p.anchoMetros, p.altoMetros, 0.62);
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  dibujarMapa(canvas, Rect.fromLTWH(0, 0, anchoPx.toDouble(), altoPx.toDouble()),
      plano: plano,
      anchoM: p.anchoMetros,
      altoM: p.altoMetros,
      calor: calor,
      mediciones: p.mediciones,
      capa: capa,
      escalaPuntos: anchoPx / 900);
  final img = await rec.endRecording().toImage(anchoPx, altoPx);
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  img.dispose();
  calor?.dispose();
  return (ancho: anchoPx, alto: altoPx, rgba: bd!.buffer.asUint8List());
}
