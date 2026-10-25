// Vantaris: escena de la pizarra. Interpreta las órdenes del protocolo (ver draw.dart) y las pinta.
//
// La usa el técnico para ver en local exactamente lo que se pinta en el equipo controlado: el
// emisor aplica aquí cada orden a la vez que la manda. Los equipos controlados tienen su propio
// pintor nativo con las mismas reglas (Android: VantarisDrawOverlay.kt; Windows:
// windows/runner/vantaris_overlay.cpp). Si se cambia algo del dibujo, cambiarlo en los tres.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Tiempos de vida, iguales en los tres pintores.
const int kVantarisHoldMs = 6000; // visible tras terminar (trazos y formas)
const int kVantarisHoldMarkMs = 20000; // números y textos: se leen con calma
const int kVantarisFadeMs = 1200;
const int kVantarisLaserMs = 1500; // el láser se apaga solo si deja de llegar posición
const int kVantarisTrailMs = 450; // estela del láser

/// Formas de la orden S.
enum VantarisShape { arrow, rect, ellipse, triangle, line }

const Map<String, VantarisShape> kVantarisShapeCodes = {
  'A': VantarisShape.arrow,
  'R': VantarisShape.rect,
  'O': VantarisShape.ellipse,
  'T': VantarisShape.triangle,
  'I': VantarisShape.line,
};

String vantarisShapeCode(VantarisShape s) =>
    kVantarisShapeCodes.entries.firstWhere((e) => e.value == s).key;

/// Texto de la orden X: base64url sin relleno (así no lleva espacios ni saltos de línea).
String vantarisEncodeText(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String vantarisDecodeText(String b64) {
  var s = b64;
  while (s.length % 4 != 0) {
    s += '=';
  }
  try {
    return utf8.decode(base64Url.decode(s));
  } catch (_) {
    return '';
  }
}

enum _Kind { stroke, shape, number, text }

class _Item {
  final _Kind kind;
  Color color;
  int widthPermille;
  final List<Offset> points = []; // normalizados 0..1
  VantarisShape shape = VantarisShape.line;
  String label = '';
  int endedAt = 0;
  int holdMs = kVantarisHoldMs;
  _Item(this.kind, this.color, this.widthPermille);
}

class VantarisScene {
  final _items = <String, _Item>{};
  Offset? _laser;
  int _laserAt = 0;
  final _trail = <MapEntry<int, Offset>>[];
  Rect? _focus; // normalizado

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  bool get isEmpty => _items.isEmpty && _laserAt == 0 && _focus == null;

  /// ¿Hay algo que se mueve (caducidades, láser)? Si sí, hay que seguir repintando.
  bool get animating =>
      _laserAt != 0 || _trail.isNotEmpty || _items.values.any((i) => i.endedAt != 0);

  void clear() {
    _items.clear();
    _focus = null;
    _laserAt = 0;
    _trail.clear();
  }

  /// Aplica un bloque de órdenes (una por línea).
  void applyAll(String body) {
    for (final l in body.split('\n')) {
      apply(l.trim());
    }
  }

  void apply(String line) {
    if (line.isEmpty) return;
    final p = line.split(' ');
    final now = _now();
    switch (p[0]) {
      case 'C':
        clear();
        break;
      case 'Z':
        if (p.length > 1) _items.remove(p[1]);
        break;
      case 'E':
        final it = p.length > 1 ? _items[p[1]] : null;
        if (it != null) {
          it.endedAt = now;
          final ms = p.length > 2 ? int.tryParse(p[2]) : null;
          if (ms != null) it.holdMs = ms;
        }
        break;
      case 'L':
        final pt = p.length > 1 ? _point(p[1]) : null;
        if (pt == null) {
          _laserAt = 0;
          _trail.clear();
        } else {
          _laser = pt;
          _laserAt = now;
          _trail.add(MapEntry(now, pt));
        }
        break;
      case 'F':
        final a = p.length > 2 ? _point(p[1]) : null;
        final b = p.length > 2 ? _point(p[2]) : null;
        _focus = (a != null && b != null) ? Rect.fromPoints(a, b) : null;
        break;
      case 'P':
        if (p.length < 4) return;
        final it = _items.putIfAbsent(
            p[1], () => _Item(_Kind.stroke, _color(p[2]), int.tryParse(p[3]) ?? 6));
        for (var i = 4; i < p.length; i++) {
          final pt = _point(p[i]);
          if (pt != null) it.points.add(pt);
        }
        break;
      case 'S':
        // S <id> <forma> <argb> <grosor> x,y x,y — se puede repetir con el mismo id mientras se arrastra.
        if (p.length < 7) return;
        final a = _point(p[5]), b = _point(p[6]);
        if (a == null || b == null) return;
        final it = _items.putIfAbsent(
            p[1], () => _Item(_Kind.shape, _color(p[3]), int.tryParse(p[4]) ?? 6));
        it.shape = kVantarisShapeCodes[p[2]] ?? VantarisShape.line;
        it.color = _color(p[3]);
        it.widthPermille = int.tryParse(p[4]) ?? 6;
        it.points
          ..clear()
          ..addAll([a, b]);
        break;
      case 'N':
        // N <id> <argb> <número> x,y
        if (p.length < 5) return;
        final pt = _point(p[4]);
        if (pt == null) return;
        _items[p[1]] = _Item(_Kind.number, _color(p[2]), 6)
          ..label = p[3]
          ..holdMs = kVantarisHoldMarkMs
          ..points.add(pt);
        break;
      case 'X':
        // X <id> <argb> x,y <texto base64url>
        if (p.length < 5) return;
        final pt = _point(p[3]);
        if (pt == null) return;
        _items[p[1]] = _Item(_Kind.text, _color(p[2]), 6)
          ..label = vantarisDecodeText(p[4])
          ..holdMs = kVantarisHoldMarkMs
          ..points.add(pt);
        break;
    }
  }

  static Offset? _point(String tok) {
    final xy = tok.split(',');
    if (xy.length != 2) return null;
    final x = double.tryParse(xy[0]), y = double.tryParse(xy[1]);
    if (x == null || y == null) return null;
    return Offset(x / 10000, y / 10000);
  }

  static Color _color(String hex) =>
      Color(int.tryParse(hex, radix: 16) ?? 0xFFE53935);

  /// Pinta la escena dentro de [area] (la pantalla remota tal y como se ve).
  void paint(Canvas canvas, Rect area) {
    final now = _now();
    final w = area.width, h = area.height;
    if (w <= 0 || h <= 0) return;
    final shortSide = math.min(w, h);
    Offset px(Offset n) => Offset(area.left + n.dx * w, area.top + n.dy * h);

    // Caducidades.
    _items.removeWhere((_, it) =>
        it.endedAt != 0 && now - it.endedAt > it.holdMs + kVantarisFadeMs);
    if (_laserAt != 0 && now - _laserAt >= kVantarisLaserMs) {
      _laserAt = 0;
      _trail.clear();
    }
    _trail.removeWhere((e) => now - e.key > kVantarisTrailMs);

    canvas.save();
    canvas.clipRect(area);

    final f = _focus;
    if (f != null) {
      final hole = Rect.fromPoints(px(f.topLeft), px(f.bottomRight));
      final dim = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(area)
        ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(8)));
      canvas.drawPath(dim, Paint()..color = const Color(0x8C000000));
      canvas.drawRRect(
          RRect.fromRectAndRadius(hole, const Radius.circular(8)),
          Paint()
            ..color = const Color(0xFF03B5A5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2, shortSide * 0.004));
    }

    for (final it in _items.values) {
      if (it.points.isEmpty) continue;
      var alpha = 1.0;
      if (it.endedAt != 0) {
        final age = now - it.endedAt;
        if (age > it.holdMs) {
          alpha = (1 - (age - it.holdMs) / kVantarisFadeMs).clamp(0.0, 1.0);
        }
      }
      final base = it.color;
      final color = base.withOpacity(base.opacity * alpha);
      final stroke = math.max(2.0, shortSide * it.widthPermille / 1000);
      final paint = Paint()
        ..color = color
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      switch (it.kind) {
        case _Kind.stroke:
          final path = Path();
          final first = px(it.points.first);
          path.moveTo(first.dx, first.dy);
          if (it.points.length == 1) path.lineTo(first.dx + 0.1, first.dy);
          for (final p in it.points.skip(1)) {
            final q = px(p);
            path.lineTo(q.dx, q.dy);
          }
          canvas.drawPath(path, paint);
          break;
        case _Kind.shape:
          if (it.points.length < 2) break;
          _paintShape(canvas, it.shape, px(it.points[0]), px(it.points[1]), paint,
              stroke);
          break;
        case _Kind.number:
          _paintNumber(canvas, px(it.points.first), it.label, color, alpha, shortSide);
          break;
        case _Kind.text:
          _paintText(canvas, px(it.points.first), it.label, color, alpha, shortSide);
          break;
      }
    }

    if (_laserAt != 0 && _laser != null) {
      if (_trail.length > 1) {
        for (var i = 1; i < _trail.length; i++) {
          final t = 1 - (now - _trail[i].key) / kVantarisTrailMs;
          canvas.drawLine(
              px(_trail[i - 1].value),
              px(_trail[i].value),
              Paint()
                ..color = Color.fromRGBO(255, 40, 40, 0.55 * t.clamp(0.0, 1.0))
                ..strokeWidth = math.max(3, shortSide * 0.008) * t.clamp(0.3, 1.0)
                ..strokeCap = StrokeCap.round);
        }
      }
      final c = px(_laser!);
      final r = math.max(6.0, shortSide * 0.009);
      canvas.drawCircle(c, r * 2.2, Paint()..color = const Color(0x46FF2828));
      canvas.drawCircle(c, r, Paint()..color = const Color(0xEBFF1E1E));
      canvas.drawCircle(c, r * 0.35, Paint()..color = const Color(0xFFFFDCDC));
    }
    canvas.restore();
  }
}

void _paintShape(Canvas canvas, VantarisShape shape, Offset a, Offset b, Paint paint,
    double stroke) {
  final r = Rect.fromPoints(a, b);
  switch (shape) {
    case VantarisShape.line:
      canvas.drawLine(a, b, paint);
      break;
    case VantarisShape.rect:
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(stroke)), paint);
      break;
    case VantarisShape.ellipse:
      canvas.drawOval(r, paint);
      break;
    case VantarisShape.triangle:
      canvas.drawPath(
          Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.bottom)
            ..lineTo(r.left, r.bottom)
            ..close(),
          paint);
      break;
    case VantarisShape.arrow:
      final d = b - a;
      final len = d.distance;
      if (len < 1) break;
      final head = math.min(len * 0.6, math.max(stroke * 4, 14.0));
      final ux = d.dx / len, uy = d.dy / len;
      // La línea acaba en la base de la punta para que no asome por delante.
      final base = Offset(b.dx - ux * head * 0.8, b.dy - uy * head * 0.8);
      canvas.drawLine(a, base, paint);
      const ang = 0.5; // ~28°
      Offset side(double s) => Offset(
          b.dx - head * (ux * math.cos(ang) - s * uy * math.sin(ang)),
          b.dy - head * (uy * math.cos(ang) + s * ux * math.sin(ang)));
      canvas.drawPath(
          Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(side(1).dx, side(1).dy)
            ..lineTo(side(-1).dx, side(-1).dy)
            ..close(),
          Paint()
            ..color = paint.color
            ..style = PaintingStyle.fill);
      break;
  }
}

/// Radio de los números de paso (mismo cálculo en los pintores nativos).
double vantarisNumberRadius(double shortSide) => math.max(14.0, shortSide * 0.022);

/// Alto de letra de los textos (mismo cálculo en los pintores nativos).
double vantarisTextSize(double shortSide) => math.max(14.0, shortSide * 0.026);

void _paintNumber(Canvas canvas, Offset c, String label, Color color, double alpha,
    double shortSide) {
  final r = vantarisNumberRadius(shortSide);
  canvas.drawCircle(c, r + r * 0.15,
      Paint()..color = Color.fromRGBO(255, 255, 255, 0.95 * alpha));
  canvas.drawCircle(c, r, Paint()..color = color);
  final tp = TextPainter(
    text: TextSpan(
        text: label,
        style: TextStyle(
            color: _onColor(color).withOpacity(alpha),
            fontSize: r * 1.15,
            fontWeight: FontWeight.bold)),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
}

void _paintText(Canvas canvas, Offset at, String label, Color color, double alpha,
    double shortSide) {
  if (label.isEmpty) return;
  final size = vantarisTextSize(shortSide);
  final tp = TextPainter(
    text: TextSpan(
        text: label,
        style: TextStyle(
            color: color.withOpacity(alpha), fontSize: size, fontWeight: FontWeight.w600)),
    textDirection: ui.TextDirection.ltr,
    maxLines: 4,
  )..layout(maxWidth: shortSide * 0.9);
  final pad = size * 0.4;
  // El punto marca el borde izquierdo, centrado en vertical.
  final box = Rect.fromLTWH(at.dx, at.dy - tp.height / 2 - pad, tp.width + pad * 2,
      tp.height + pad * 2);
  canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(pad)),
      Paint()..color = Color.fromRGBO(0, 0, 0, 0.78 * alpha));
  tp.paint(canvas, Offset(at.dx + pad, at.dy - tp.height / 2));
}

/// Blanco o negro, lo que se lea mejor encima de [c] (el amarillo necesita negro).
Color _onColor(Color c) =>
    c.computeLuminance() > 0.5 ? const Color(0xFF111111) : Colors.white;
