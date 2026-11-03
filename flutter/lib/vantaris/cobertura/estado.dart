// Vantaris Cobertura: estado de la herramienta (proyecto, mapa, «en vivo», redes) y archivos.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'mapa.dart';
import 'modelo.dart';
import 'sensores.dart';

const kMuestrasVivo = 150;

class EstadoCobertura extends ChangeNotifier {
  Proyecto proyecto = const Proyecto();
  ui.Image? plano;
  ui.Image? calor;
  Capa capa = Capa.wifi;
  double opacidad = 0.6;
  bool conVelocidad = false;
  String? midiendo;
  int? seleccion;
  List<RedWifi> redes = const [];
  bool buscandoRedes = false;
  String? errorRedes;
  String? routerIp;
  String? avisoWifi;
  bool tieneMovil = false;

  // En vivo
  bool vivoActivo = false;
  String vivoHost = kHostInternet;
  final vivoPing = <double?>[];
  final vivoWifi = <int?>[];
  final vivoMovil = <int?>[];
  int vivoEnviados = 0, vivoRecibidos = 0;
  String? vivoSsid;
  int? vivoCanal;

  bool _cerrado = false;
  int _genCalor = 0;

  Sensores get s => Sensores.actual;

  Future<void> iniciar() async {
    await s.pedirPermisos();
    tieneMovil = await s.tieneMovil();
    routerIp = await s.puertaEnlace();
    final w = await s.wifi();
    avisoWifi = w.error;
    vivoSsid = w.valor?.ssid;
    vivoCanal = w.valor?.canal;
    _avisar();
  }

  /// Vuelve a mirar la WiFi (al volver de Ajustes tras dar el permiso).
  Future<void> refrescarWifi() async {
    final w = await s.wifi();
    avisoWifi = w.error;
    vivoSsid = w.valor?.ssid ?? vivoSsid;
    routerIp ??= await s.puertaEnlace();
    _avisar();
  }

  void _avisar() {
    if (!_cerrado) notifyListeners();
  }

  @override
  void dispose() {
    _cerrado = true;
    vivoActivo = false;
    calor?.dispose();
    super.dispose();
  }

  void cambiar(void Function() f, {bool recalcular = false}) {
    f();
    _avisar();
    if (recalcular) recalcularCalor();
  }

  Future<void> recalcularCalor() async {
    final gen = ++_genCalor;
    final img = await mapaCalor(proyecto.mediciones, capa, proyecto.anchoMetros, proyecto.altoMetros, opacidad);
    if (gen != _genCalor || _cerrado) {
      img?.dispose();
      return;
    }
    final viejo = calor;
    calor = img;
    _avisar();
    // El painter puede estar pintando con la vieja en este frame: se suelta después.
    Future.delayed(const Duration(milliseconds: 500), () => viejo?.dispose());
  }

  // ---------------------------------------------------------------- mediciones

  Future<String?> medirEn(double x, double y) async {
    if (midiendo != null) return null;
    midiendo = 'Preparando…';
    _avisar();
    try {
      routerIp ??= await s.puertaEnlace();
      final w = await s.wifi();
      avisoWifi = w.error;
      final m = await medirPunto(
          x: x,
          y: y,
          conVelocidad: conVelocidad,
          router: routerIp,
          paso: (t) {
            midiendo = t;
            _avisar();
          });
      proyecto = proyecto.copia(mediciones: [...proyecto.mediciones, m]);
      seleccion = m.id;
      recalcularCalor();
      return null;
    } catch (e) {
      return 'No se pudo medir: $e';
    } finally {
      midiendo = null;
      _avisar();
    }
  }

  void borrar(int id) => cambiar(() {
        proyecto = proyecto.copia(mediciones: proyecto.mediciones.where((m) => m.id != id).toList());
        if (seleccion == id) seleccion = null;
      }, recalcular: true);

  void borrarTodo() => cambiar(() {
        proyecto = proyecto.copia(mediciones: const []);
        seleccion = null;
      }, recalcular: true);

  void nota(int id, String t) {
    // Sin notifyListeners: lo pinta el propio campo de texto; el resto se entera al cambiar algo más.
    proyecto = proyecto.copia(mediciones: [for (final m in proyecto.mediciones) m.id == id ? m.conNota(t) : m]);
  }

  // ---------------------------------------------------------------- plano y proyecto

  Future<bool> cargarPlano(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      var img = (await codec.getNextFrame()).image;
      // Reducir a 1800 px de lado como mucho: el JSON lleva el plano dentro.
      final lado = img.width > img.height ? img.width : img.height;
      if (lado > 1800) {
        final k = 1800 / lado;
        final c2 = await ui.instantiateImageCodec(bytes,
            targetWidth: (img.width * k).round(), targetHeight: (img.height * k).round());
        img.dispose();
        img = (await c2.getNextFrame()).image;
      }
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      plano?.dispose();
      plano = img;
      proyecto = proyecto.copia(
        planoBase64: base64Encode(png!.buffer.asUint8List()),
        altoMetros: proyecto.anchoMetros * img.height / img.width,
      );
      _avisar();
      recalcularCalor();
      return true;
    } catch (_) {
      return false;
    }
  }

  void quitarPlano() => cambiar(() {
        plano?.dispose();
        plano = null;
        proyecto = proyecto.copia(quitarPlano: true);
      });

  void cambiarAncho(double m) {
    final p = plano;
    proyecto = p != null
        ? proyecto.copia(anchoMetros: m, altoMetros: m * p.height / p.width)
        : proyecto.copia(anchoMetros: m);
    _avisar();
    recalcularCalor();
  }

  void cambiarFondo(double m) {
    proyecto = proyecto.copia(altoMetros: m);
    _avisar();
    recalcularCalor();
  }

  Future<void> abrir(Uint8List bytes) async {
    final p = Proyecto.deJson(utf8.decode(bytes));
    ui.Image? img;
    if (p.planoBase64 != null) {
      try {
        final codec = await ui.instantiateImageCodec(base64Decode(p.planoBase64!));
        img = (await codec.getNextFrame()).image;
      } catch (_) {}
    }
    plano?.dispose();
    plano = img;
    proyecto = p;
    seleccion = null;
    _avisar();
    recalcularCalor();
  }

  // ---------------------------------------------------------------- en vivo

  void reiniciarVivo() => cambiar(() {
        vivoPing.clear();
        vivoWifi.clear();
        vivoMovil.clear();
        vivoEnviados = 0;
        vivoRecibidos = 0;
      });

  void cambiarHostVivo(String h) {
    vivoHost = h;
    reiniciarVivo();
  }

  /// Bucle de «en vivo»: sigue aunque cambies de pestaña, para mirar el mapa mientras caminas.
  Future<void> alternarVivo() async {
    if (vivoActivo) {
      vivoActivo = false;
      _avisar();
      return;
    }
    vivoActivo = true;
    _avisar();
    var vuelta = 0;
    while (vivoActivo && !_cerrado) {
      final sw = Stopwatch()..start();
      final host = vivoHost;
      final ping = await Red.ping(host);
      final w = (await s.wifi()).valor;
      int? movil = vivoMovil.isEmpty ? null : vivoMovil.last;
      if (tieneMovil && vuelta % 2 == 0) movil = (await s.movil())?.dbm;
      if (!vivoActivo || _cerrado) break;
      if (host == vivoHost) {
        vivoSsid = w?.ssid;
        vivoCanal = w?.canal;
        vivoEnviados++;
        if (ping != null) vivoRecibidos++;
        void meter<T>(List<T> l, T v) {
          l.add(v);
          if (l.length > kMuestrasVivo) l.removeAt(0);
        }

        meter(vivoPing, ping);
        meter(vivoWifi, w?.rssi);
        meter(vivoMovil, movil);
        _avisar();
      }
      vuelta++;
      final resto = 1000 - sw.elapsedMilliseconds;
      await Future.delayed(Duration(milliseconds: resto < 50 ? 50 : resto));
    }
  }

  // ---------------------------------------------------------------- redes

  Future<void> buscarRedes() async {
    if (buscandoRedes) return;
    buscandoRedes = true;
    _avisar();
    final r = await s.redes();
    if (r.valor != null) redes = r.valor!;
    errorRedes = r.error;
    buscandoRedes = false;
    _avisar();
  }
}

String nombreArchivo(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(RegExp(r'[a-z0-9áéíóúñü]').hasMatch(ch) ? ch : '-');
  }
  var r = b.toString().replaceAll(RegExp(r'-+'), '-');
  r = r.replaceAll(RegExp(r'^-|-$'), '');
  return r.isEmpty ? 'cobertura' : r;
}

// ---------------------------------------------------------------- archivos

class Guardado {
  final String ruta;
  final String? uri; // Android: content:// para compartir
  final String mime;
  const Guardado(this.ruta, this.uri, this.mime);
}

const _mChannel = MethodChannel('mChannel');

/// Android: Descargas/Vantaris. Windows: Documentos\Vantaris\Cobertura.
Future<Guardado> guardarArchivo(String nombre, String mime, Uint8List datos) async {
  if (Platform.isAndroid) {
    final r = jsonDecode(await _mChannel.invokeMethod<String>(
            'vantaris_cobertura',
            jsonEncode({'orden': 'guardar', 'nombre': nombre, 'mime': mime, 'datos': base64Encode(datos)})) ??
        '{}') as Map;
    if (r['ok'] != true) throw Exception(r['error'] ?? 'no se pudo guardar');
    return Guardado(r['ruta'] as String, r['uri'] as String?, mime);
  }
  final docs = Platform.environment['USERPROFILE'] ?? Directory.current.path;
  final dir = Directory('$docs\\Documents\\Vantaris\\Cobertura');
  await dir.create(recursive: true);
  final f = File('${dir.path}\\$nombre');
  await f.writeAsBytes(datos, flush: true);
  return Guardado(f.path, null, mime);
}

/// Android: menú de compartir (WhatsApp, correo…). Windows: abre la carpeta con el archivo marcado.
Future<String?> compartirArchivo(Guardado g) async {
  if (Platform.isAndroid) {
    final r = jsonDecode(await _mChannel.invokeMethod<String>(
            'vantaris_cobertura', jsonEncode({'orden': 'compartir', 'uri': g.uri, 'mime': g.mime})) ??
        '{}') as Map;
    return r['error'] as String?;
  }
  try {
    await Process.start('explorer.exe', ['/select,', g.ruta]);
  } catch (e) {
    return '$e';
  }
  return null;
}

/// Elige una foto o imagen del plano. En Android se puede hacer la foto en el momento.
Future<Uint8List?> elegirImagen({bool camara = false}) async {
  if (Platform.isAndroid) {
    final x = await ImagePicker().pickImage(
        source: camara ? ImageSource.camera : ImageSource.gallery, maxWidth: 2400, maxHeight: 2400);
    return x == null ? null : await x.readAsBytes();
  }
  final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
  return r?.files.single.bytes ?? (r?.files.single.path != null ? await File(r!.files.single.path!).readAsBytes() : null);
}

Future<Uint8List?> elegirProyecto() async {
  final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
  final f = r?.files.single;
  if (f == null) return null;
  return f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
}
