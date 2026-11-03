// Vantaris Cobertura: pantalla de la herramienta dentro de Vantaris Soporte.
//
// Cuatro pestañas: Mapa (tocar el plano donde estás → mide WiFi, móvil, ping y, si se quiere,
// velocidad; mapa de calor), En vivo (ping continuo mientras caminas), Redes (redes de alrededor y
// canal más libre) e Informe (PDF para el cliente, CSV y proyecto JSON).
// Android: se abre desde la pantalla principal (mobile/pages/server_page.dart). Windows: como
// pestaña de la ventana principal (desktop/pages/desktop_tab_page.dart).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'estado.dart';
import 'informe.dart';
import 'mapa.dart';
import 'modelo.dart';

const kCoberturaTeal = Color(0xFF03B5A5);
const _verdeOscuro = Color(0xFF0A7B71);

class CoberturaPagina extends StatefulWidget {
  /// Android: página propia con barra y botón de volver. Windows: va dentro de una pestaña.
  final bool conBarra;
  const CoberturaPagina({Key? key, this.conBarra = false}) : super(key: key);

  @override
  State<CoberturaPagina> createState() => _CoberturaPaginaState();
}

class _CoberturaPaginaState extends State<CoberturaPagina> with WidgetsBindingObserver {
  final e = EstadoCobertura();
  int pestana = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    e.iniciar();
    e.recalcularCalor();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver de Ajustes (permiso de ubicación) se vuelve a leer la WiFi.
    if (state == AppLifecycleState.resumed) e.refrescarWifi();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    e.dispose();
    super.dispose();
  }

  static const _pestanas = [
    (nombre: 'Mapa', icono: Icons.map_outlined),
    (nombre: 'En vivo', icono: Icons.monitor_heart_outlined),
    (nombre: 'Redes', icono: Icons.wifi),
    (nombre: 'Informe', icono: Icons.description_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: e,
      builder: (context, _) => LayoutBuilder(builder: (context, c) {
        final estrecho = c.maxWidth < 640;
        final subtitulo = [
          if (e.vivoSsid != null) 'WiFi: ${e.vivoSsid}',
          if (e.routerIp != null) 'router ${e.routerIp}',
        ].join(' · ');
        final cuerpo = switch (pestana) {
          0 => _TabMapa(e),
          1 => _TabVivo(e),
          2 => _TabRedes(e),
          _ => _TabInforme(e),
        };
        return Scaffold(
          appBar: widget.conBarra
              ? AppBar(
                  title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Cobertura del local', style: TextStyle(fontSize: 17)),
                    Text(subtitulo.isEmpty ? 'Mapa de señal WiFi y móvil' : subtitulo,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
                  ]),
                  actions: [if (e.vivoActivo) const _PuntoVivo()],
                )
              : null,
          body: Column(children: [
            if (!widget.conBarra || !estrecho)
              _Cabecera(
                subtitulo: subtitulo,
                mostrarTitulo: !widget.conBarra,
                vivo: e.vivoActivo,
                pestanas: estrecho
                    ? null
                    : SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: [
                          for (var i = 0; i < _pestanas.length; i++)
                            ButtonSegment(value: i, icon: Icon(_pestanas[i].icono, size: 18), label: Text(_pestanas[i].nombre)),
                        ],
                        selected: {pestana},
                        onSelectionChanged: (s) => setState(() => pestana = s.first),
                      ),
              ),
            Expanded(child: cuerpo),
          ]),
          bottomNavigationBar: estrecho
              ? NavigationBar(
                  selectedIndex: pestana,
                  height: 64,
                  onDestinationSelected: (i) => setState(() => pestana = i),
                  destinations: [
                    for (final p in _pestanas) NavigationDestination(icon: Icon(p.icono), label: p.nombre),
                  ],
                )
              : null,
        );
      }),
    );
  }
}

class _PuntoVivo extends StatelessWidget {
  const _PuntoVivo();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(right: 14),
        child: Row(children: [
          Icon(Icons.circle, size: 10, color: Colors.redAccent),
          SizedBox(width: 4),
          Text('en vivo', style: TextStyle(fontSize: 12)),
        ]),
      );
}

class _Cabecera extends StatelessWidget {
  final String subtitulo;
  final bool mostrarTitulo;
  final bool vivo;
  final Widget? pestanas;
  const _Cabecera({required this.subtitulo, required this.mostrarTitulo, required this.vivo, this.pestanas});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surface,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          if (mostrarTitulo) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: const LinearGradient(colors: [Color(0xFF0F1A30), _verdeOscuro]),
              ),
              child: const Icon(Icons.wifi_tethering, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Cobertura del local', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text(subtitulo.isEmpty ? 'Mapa de señal WiFi y móvil' : subtitulo,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.hintColor)),
              ]),
            ),
            if (vivo) const _PuntoVivo(),
          ] else
            const Spacer(),
          if (pestanas != null) pestanas!,
        ]),
      ),
    );
  }
}

// ======================================================================== utilidades de UI

void _aviso(BuildContext context, String t, {SnackBarAction? accion}) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t), action: accion, duration: const Duration(seconds: 6)));
}

Future<void> _guardar(BuildContext context, String nombre, String mime, Future<Uint8List> Function() datos) async {
  _aviso(context, 'Preparando $nombre…');
  try {
    final g = await guardarArchivo(nombre, mime, await datos());
    if (!context.mounted) return;
    _aviso(context, 'Guardado en ${g.ruta}',
        accion: SnackBarAction(
          label: Theme.of(context).platform == TargetPlatform.android ? 'Compartir' : 'Abrir carpeta',
          onPressed: () async {
            final err = await compartirArchivo(g);
            if (err != null && context.mounted) _aviso(context, err);
          },
        ));
  } catch (err) {
    if (context.mounted) _aviso(context, 'No se pudo guardar: $err');
  }
}

class _Seccion extends StatefulWidget {
  final String titulo;
  final IconData icono;
  final bool abierta;
  final String? resumen;
  final List<Widget> hijos;
  const _Seccion(this.titulo, this.icono, this.hijos, {this.abierta = true, this.resumen});

  @override
  State<_Seccion> createState() => _SeccionState();
}

class _SeccionState extends State<_Seccion> {
  late bool abierta = widget.abierta;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: t.colorScheme.surfaceContainerHighest.withOpacity(0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => abierta = !abierta),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: kCoberturaTeal.withOpacity(0.15), borderRadius: BorderRadius.circular(9)),
                child: Icon(widget.icono, size: 18, color: kCoberturaTeal),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.titulo, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
              if (!abierta && widget.resumen != null)
                Text(widget.resumen!, style: TextStyle(fontSize: 12, color: t.hintColor)),
              Icon(abierta ? Icons.expand_less : Icons.expand_more, color: t.hintColor),
            ]),
          ),
          if (abierta) ...[
            const SizedBox(height: 12),
            ...widget.hijos.expand((w) => [w, const SizedBox(height: 10)]).take(widget.hijos.length * 2 - 1),
          ],
        ]),
      ),
    );
  }
}

Widget _tarjeta(BuildContext context, List<Widget> hijos, {EdgeInsets padding = const EdgeInsets.all(16)}) => Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: hijos),
      ),
    );

Widget _chips<T>(List<T> opciones, T elegida, String Function(T) nombre, void Function(T) alElegir) => Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final o in opciones)
          ChoiceChip(
            label: Text(nombre(o)),
            selected: o == elegida,
            selectedColor: kCoberturaTeal.withOpacity(0.25),
            onSelected: (_) => alElegir(o),
          ),
      ],
    );

String valorTexto(Capa c, double? v) => v == null ? '—' : '${fmt(v, c.decimales)} ${c.unidad}';

// ======================================================================== Mapa

class _TabMapa extends StatelessWidget {
  final EstadoCobertura e;
  const _TabMapa(this.e);

  Future<void> _medir(BuildContext context, double x, double y) async {
    final err = await e.medirEn(x, y);
    if (err != null && context.mounted) _aviso(context, err);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final lienzo = _Lienzo(e, (x, y) => _medir(context, x, y));
      final panel = _PanelMapa(e, (x, y) => _medir(context, x, y));
      if (c.maxWidth >= 900) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: lienzo),
            const SizedBox(width: 16),
            SizedBox(width: 390, child: ListView(children: [panel])),
          ]),
        );
      }
      return ListView(padding: const EdgeInsets.all(12), children: [
        SizedBox(height: math.min(460.0, math.max(300.0, c.maxHeight * 0.6)), child: lienzo),
        const SizedBox(height: 12),
        panel,
        const SizedBox(height: 24),
      ]);
    });
  }
}

class _Lienzo extends StatefulWidget {
  final EstadoCobertura e;
  final void Function(double x, double y) medirEn;
  const _Lienzo(this.e, this.medirEn);

  @override
  State<_Lienzo> createState() => _LienzoState();
}

class _LienzoState extends State<_Lienzo> {
  double zoom = 1;
  Offset pan = Offset.zero;
  double _zoomInicio = 1;
  Offset _focoInicio = Offset.zero, _panInicio = Offset.zero;

  Rect _caja(Size s) {
    final p = widget.e.proyecto;
    final b = encajar(s, p.anchoMetros, p.altoMetros, margen: 20);
    final cx = s.width / 2, cy = s.height / 2;
    return Rect.fromLTWH(cx + (b.left - cx) * zoom + pan.dx, cy + (b.top - cy) * zoom + pan.dy, b.width * zoom, b.height * zoom);
  }

  void _tocar(Offset t, Size s) {
    final e = widget.e;
    final b = _caja(s);
    // ¿Toca un punto ya medido? → seleccionarlo.
    Medicion? cerca;
    var dmin = double.infinity;
    for (final m in e.proyecto.mediciones) {
      final d = (Offset(b.left + m.x * b.width, b.top + m.y * b.height) - t).distance;
      if (d < dmin) {
        dmin = d;
        cerca = m;
      }
    }
    if (cerca != null && dmin < 26) {
      e.cambiar(() => e.seleccion = e.seleccion == cerca!.id ? null : cerca.id);
      return;
    }
    final x = (t.dx - b.left) / b.width, y = (t.dy - b.top) / b.height;
    if (x >= 0 && x <= 1 && y >= 0 && y <= 1) widget.medirEn(x, y);
  }

  void _zoom(double f) => setState(() {
        zoom = (zoom * f).clamp(1.0, 8.0);
        if (zoom == 1) pan = Offset.zero;
      });

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final t = Theme.of(context);
    final oscuro = t.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        color: oscuro ? const Color(0xFF0E1626) : const Color(0xFFEFF3F8),
        child: LayoutBuilder(builder: (context, c) {
          final s = Size(c.maxWidth, c.maxHeight);
          return Stack(children: [
            Positioned.fill(
              child: Listener(
                onPointerSignal: (ev) {
                  if (ev is PointerScrollEvent) _zoom(ev.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15);
                },
                child: GestureDetector(
                  onTapUp: (d) => _tocar(d.localPosition, s),
                  onScaleStart: (d) {
                    _zoomInicio = zoom;
                    _focoInicio = d.localFocalPoint;
                    _panInicio = pan;
                  },
                  onScaleUpdate: (d) => setState(() {
                    zoom = (_zoomInicio * d.scale).clamp(1.0, 8.0);
                    pan = zoom == 1 ? Offset.zero : _panInicio + (d.localFocalPoint - _focoInicio);
                  }),
                  child: CustomPaint(
                    painter: _LienzoPainter(
                      proyecto: e.proyecto,
                      plano: e.plano,
                      calor: e.calor,
                      capa: e.capa,
                      seleccion: e.seleccion,
                      oscuro: oscuro,
                      caja: _caja(s),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: Row(children: [
                _BotonMapa(Icons.add, 'Acercar', () => _zoom(1.4)),
                _BotonMapa(Icons.remove, 'Alejar', () => _zoom(1 / 1.4)),
                _BotonMapa(Icons.center_focus_strong, 'Centrar', () => setState(() {
                      zoom = 1;
                      pan = Offset.zero;
                    })),
              ]),
            ),
            Positioned(left: 10, bottom: 10, child: _Leyenda(e.capa)),
            if (e.proyecto.mediciones.isEmpty && e.midiendo == null)
              Positioned(
                left: 10,
                top: 10,
                right: 10,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _Globo(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.touch_app, color: kCoberturaTeal),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text('Ponte en un sitio del local y toca ese punto del plano para medir',
                            style: TextStyle(fontSize: 12.5, color: t.colorScheme.onSurface)),
                      ),
                    ]),
                  ),
                ),
              ),
            if (e.midiendo != null)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: SizedBox(
                    width: 300,
                    child: _Globo(
                      color: kCoberturaTeal.withOpacity(0.95),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Midiendo — no te muevas',
                            style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                        Text(e.midiendo!, style: const TextStyle(fontSize: 12, color: Colors.white)),
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(color: Colors.white, backgroundColor: Colors.white24),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class _LienzoPainter extends CustomPainter {
  final Proyecto proyecto;
  final ui.Image? plano, calor;
  final Capa capa;
  final int? seleccion;
  final bool oscuro;
  final Rect caja;
  _LienzoPainter({
    required this.proyecto,
    required this.plano,
    required this.calor,
    required this.capa,
    required this.seleccion,
    required this.oscuro,
    required this.caja,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final escala = (math.min(caja.width, caja.height) / 420).clamp(0.75, 1.4).toDouble();
    dibujarMapa(canvas, caja,
        plano: plano,
        anchoM: proyecto.anchoMetros,
        altoM: proyecto.altoMetros,
        calor: calor,
        mediciones: proyecto.mediciones,
        capa: capa,
        seleccion: seleccion,
        escalaPuntos: escala,
        oscuro: oscuro);
  }

  @override
  bool shouldRepaint(_LienzoPainter o) =>
      o.proyecto != proyecto ||
      o.plano != plano ||
      o.calor != calor ||
      o.capa != capa ||
      o.seleccion != seleccion ||
      o.oscuro != oscuro ||
      o.caja != caja;
}

class _Globo extends StatelessWidget {
  final Widget child;
  final Color? color;
  const _Globo({required this.child, this.color});
  @override
  Widget build(BuildContext context) => Material(
        color: color ?? Theme.of(context).colorScheme.surface.withOpacity(0.94),
        elevation: 3,
        borderRadius: BorderRadius.circular(14),
        child: Padding(padding: const EdgeInsets.all(12), child: child),
      );
}

class _BotonMapa extends StatelessWidget {
  final IconData icono;
  final String ayuda;
  final VoidCallback alPulsar;
  const _BotonMapa(this.icono, this.ayuda, this.alPulsar);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: Theme.of(context).colorScheme.surface.withOpacity(0.94),
          shape: const CircleBorder(),
          elevation: 2,
          child: IconButton(icon: Icon(icono), tooltip: ayuda, onPressed: alPulsar),
        ),
      );
}

class _Leyenda extends StatelessWidget {
  final Capa capa;
  const _Leyenda(this.capa);

  @override
  Widget build(BuildContext context) {
    final (izq, der) = switch (capa) {
      Capa.wifi => ('-85 dBm', '-50 dBm'),
      Capa.movil => ('-120 dBm', '-85 dBm'),
      Capa.latencia => ('200 ms', '20 ms'),
      Capa.perdida => ('7 %', '0 %'),
      Capa.velocidad => ('0,5 Mbps', '30 Mbps'),
    };
    final gris = Theme.of(context).hintColor;
    return _Globo(
      child: SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(capa.nombre, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(colors: [for (var i = 0; i <= 10; i++) colorCalidad(i / 10)]),
            ),
          ),
          Row(children: [
            Expanded(child: Text(izq, style: TextStyle(fontSize: 10.5, color: gris))),
            Text(der, style: TextStyle(fontSize: 10.5, color: gris)),
          ]),
        ]),
      ),
    );
  }
}

class _PanelMapa extends StatelessWidget {
  final EstadoCobertura e;
  final void Function(double x, double y) medirEn;
  const _PanelMapa(this.e, this.medirEn);

  @override
  Widget build(BuildContext context) {
    final p = e.proyecto;
    final t = Theme.of(context);
    final android = t.platform == TargetPlatform.android;
    Medicion? sel;
    var nSel = 0;
    for (var i = 0; i < p.mediciones.length; i++) {
      if (p.mediciones[i].id == e.seleccion) {
        sel = p.mediciones[i];
        nSel = i + 1;
      }
    }

    Future<void> plano({bool camara = false}) async {
      final b = await elegirImagen(camara: camara);
      if (b == null) return;
      if (!await e.cargarPlano(b) && context.mounted) _aviso(context, 'No se ha podido abrir esa imagen');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (e.avisoWifi != null) ...[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.amber.withOpacity(0.18), borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.avisoWifi!, style: const TextStyle(fontSize: 13)),
            TextButton.icon(
              onPressed: () => e.s.abrirAjustes(),
              icon: const Icon(Icons.settings),
              label: const Text('Abrir ajustes'),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      _Seccion('Qué ver en el mapa', Icons.layers_outlined, [
        _chips(Capa.values, e.capa, (c) => c.nombre, (c) => e.cambiar(() => e.capa = c, recalcular: true)),
        Row(children: [
          const Text('Intensidad del color'),
          Expanded(
            child: Slider(
              value: e.opacidad,
              min: 0.2,
              max: 0.9,
              activeColor: kCoberturaTeal,
              onChanged: (v) => e.cambiar(() => e.opacidad = v),
              onChangeEnd: (_) => e.recalcularCalor(),
            ),
          ),
          Text('${(e.opacidad * 100).round()} %', style: const TextStyle(color: kCoberturaTeal)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: e.conVelocidad,
          activeColor: kCoberturaTeal,
          title: const Text('Incluir prueba de velocidad'),
          subtitle: const Text('Tarda 5 s más por punto y gasta datos'),
          onChanged: (v) => e.cambiar(() => e.conVelocidad = v),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: kCoberturaTeal, minimumSize: const Size.fromHeight(46)),
          onPressed: e.midiendo == null ? () => medirEn(0.5, 0.5) : null,
          icon: const Icon(Icons.location_on),
          label: const Text('Medir en el centro (o toca el plano)'),
        ),
      ]),
      if (sel != null) ...[const SizedBox(height: 12), _DetallePunto(e, nSel, sel)],
      const SizedBox(height: 12),
      _Seccion('Plano del local', Icons.square_foot, abierta: p.mediciones.isEmpty, [
        _CampoTexto(
            etiqueta: 'Nombre del local',
            valor: p.nombre,
            alCambiar: (v) => e.cambiar(() => e.proyecto = e.proyecto.copia(nombre: v))),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _CampoMetros('Ancho (m)', p.anchoMetros, e.cambiarAncho)),
          const SizedBox(width: 8),
          Expanded(
            child: e.plano == null
                ? _CampoMetros('Fondo (m)', p.altoMetros, e.cambiarFondo)
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Fondo: ${fmt(p.altoMetros, 1)} m\n(según la foto)', style: const TextStyle(fontSize: 12)),
                  ),
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () => plano(),
            icon: const Icon(Icons.image_outlined),
            label: Text(e.plano == null ? 'Subir foto o plano' : 'Cambiar plano'),
          ),
          if (android)
            FilledButton.tonalIcon(
              onPressed: () => plano(camara: true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Hacer foto'),
            ),
          if (e.plano != null) OutlinedButton(onPressed: e.quitarPlano, child: const Text('Quitar plano')),
        ]),
        Text(
          'Vale una foto del plano, un croquis hecho a mano o una captura de Google Maps. Sin plano se usa una cuadrícula de 1 m.',
          style: TextStyle(fontSize: 12, color: t.hintColor),
        ),
      ]),
      const SizedBox(height: 12),
      _Seccion('Proyecto', Icons.save_outlined, abierta: false, resumen: '${p.mediciones.length} puntos', [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () => _guardar(context, '${nombreArchivo(p.nombre)}.cobertura.json', 'application/json',
                () async => _utf8(e.proyecto.aJson())),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Guardar'),
          ),
          FilledButton.tonalIcon(
            onPressed: () async {
              final b = await elegirProyecto();
              if (b == null) return;
              try {
                await e.abrir(b);
                if (context.mounted) _aviso(context, 'Proyecto abierto: ${e.proyecto.nombre}');
              } catch (_) {
                if (context.mounted) _aviso(context, 'Ese archivo no es un proyecto de cobertura');
              }
            },
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Abrir'),
          ),
          if (p.mediciones.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('¿Borrar todas las mediciones?'),
                    content: Text('Se quitan los ${p.mediciones.length} puntos. El plano se queda.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Borrar')),
                    ],
                  ),
                );
                if (ok == true) e.borrarTodo();
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Borrar mediciones'),
            ),
        ]),
      ]),
      if (p.mediciones.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Seccion('Puntos medidos', Icons.location_on_outlined, abierta: false, resumen: '${p.mediciones.length}', [
          for (var i = 0; i < p.mediciones.length; i++)
            _FilaPunto(e, i, p.mediciones[i]),
        ]),
      ],
    ]);
  }
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

class _FilaPunto extends StatelessWidget {
  final EstadoCobertura e;
  final int i;
  final Medicion m;
  const _FilaPunto(this.e, this.i, this.m);

  @override
  Widget build(BuildContext context) {
    final v = e.capa.valor(m);
    final elegido = m.id == e.seleccion;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => e.cambiar(() => e.seleccion = m.id),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: elegido ? kCoberturaTeal.withOpacity(0.15) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: v == null ? const Color(0xFF94A3B8) : colorCalidad(e.capa.calidad(v)),
            child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(m.nota.trim().isNotEmpty ? m.nota : (m.wifi?.ssid ?? 'Punto ${i + 1}'),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text(valorTexto(e.capa, v), style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _DetallePunto extends StatelessWidget {
  final EstadoCobertura e;
  final int n;
  final Medicion m;
  const _DetallePunto(this.e, this.n, this.m);

  @override
  Widget build(BuildContext context) {
    final w = m.wifi;
    final filas = <Widget>[
      _FilaDato('WiFi', w?.rssi != null ? '${w!.rssi} dBm' : 'sin datos',
          w?.rssi != null ? Capa.wifi.nivel(w!.rssi!.toDouble()) : null,
          [if (w?.ssid != null) w!.ssid!, if (w?.canal != null) 'canal ${w!.canal}', if (w?.velocidadMbps != null) '${fmt(w!.velocidadMbps)} Mbps'].join(' · ')),
      if (m.movil != null)
        _FilaDato('Móvil', m.movil!.dbm != null ? '${m.movil!.dbm} dBm' : 'sin datos',
            m.movil!.dbm != null ? Capa.movil.nivel(m.movil!.dbm!.toDouble()) : null,
            [if (m.movil!.tipo != null) m.movil!.tipo!, if (m.movil!.operador != null) m.movil!.operador!].join(' · ')),
      if (m.pingRouter != null)
        _FilaDato('Router', m.pingRouter!.mediaMs != null ? '${fmt(m.pingRouter!.mediaMs)} ms' : 'no responde',
            m.pingRouter!.mediaMs != null ? Capa.latencia.nivel(m.pingRouter!.mediaMs!) : null,
            '${m.pingRouter!.host} · pérdida ${fmt(m.pingRouter!.perdida)} %'),
      if (m.pingInternet != null)
        _FilaDato('Internet', m.pingInternet!.mediaMs != null ? '${fmt(m.pingInternet!.mediaMs)} ms' : 'sin conexión',
            m.pingInternet!.mediaMs != null ? Capa.latencia.nivel(m.pingInternet!.mediaMs!) : null,
            'jitter ${fmt(m.pingInternet!.jitterMs)} ms · pérdida ${fmt(m.pingInternet!.perdida)} %'),
      if (m.velocidadMbps != null)
        _FilaDato('Velocidad', '${fmt(m.velocidadMbps, 1)} Mbps', Capa.velocidad.nivel(m.velocidadMbps!), 'descarga'),
    ];
    return _tarjeta(context, [
      Row(children: [
        Expanded(child: Text('Punto $n', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        TextButton.icon(onPressed: () => e.borrar(m.id), icon: const Icon(Icons.delete_outline), label: const Text('Borrar')),
      ]),
      ...filas.expand((f) => [f, const SizedBox(height: 8)]),
      _CampoTexto(
        key: ValueKey('nota-${m.id}'),
        etiqueta: 'Nota (p. ej. «barra», «terraza», «cocina»)',
        valor: m.nota,
        alCambiar: (t) => e.nota(m.id, t),
      ),
    ]);
  }
}

class _FilaDato extends StatelessWidget {
  final String titulo, valor, detalle;
  final Nivel? nivel;
  const _FilaDato(this.titulo, this.valor, this.nivel, this.detalle);

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).hintColor;
    return Row(children: [
      CircleAvatar(radius: 5, backgroundColor: nivel != null ? colorNivel(nivel!) : const Color(0xFF94A3B8)),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titulo, style: TextStyle(fontSize: 12, color: gris)),
          if (detalle.isNotEmpty) Text(detalle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
        ]),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(valor, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (nivel != null) Text(nivel!.nombre, style: TextStyle(fontSize: 11, color: colorNivel(nivel!))),
      ]),
    ]);
  }
}

class _CampoTexto extends StatefulWidget {
  final String etiqueta;
  final String valor;
  final void Function(String) alCambiar;
  final TextInputType? teclado;
  const _CampoTexto({Key? key, required this.etiqueta, required this.valor, required this.alCambiar, this.teclado})
      : super(key: key);

  @override
  State<_CampoTexto> createState() => _CampoTextoState();
}

class _CampoTextoState extends State<_CampoTexto> {
  late final c = TextEditingController(text: widget.valor);

  @override
  void didUpdateWidget(_CampoTexto old) {
    super.didUpdateWidget(old);
    // Proyecto abierto desde archivo: el valor cambia por fuera.
    if (widget.valor != c.text && widget.valor != old.valor) c.text = widget.valor;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: c,
        keyboardType: widget.teclado,
        decoration: InputDecoration(labelText: widget.etiqueta, border: const OutlineInputBorder(), isDense: true),
        onChanged: widget.alCambiar,
      );
}

class _CampoMetros extends StatelessWidget {
  final String etiqueta;
  final double valor;
  final void Function(double) alCambiar;
  const _CampoMetros(this.etiqueta, this.valor, this.alCambiar);

  @override
  Widget build(BuildContext context) => _CampoTexto(
        etiqueta: etiqueta,
        valor: fmt(valor, 1),
        teclado: const TextInputType.numberWithOptions(decimal: true),
        alCambiar: (t) {
          final v = double.tryParse(t.replaceAll(',', '.'));
          if (v != null && v >= 1 && v <= 500) alCambiar(v);
        },
      );
}

// ======================================================================== En vivo

class _TabVivo extends StatefulWidget {
  final EstadoCobertura e;
  const _TabVivo(this.e);
  @override
  State<_TabVivo> createState() => _TabVivoState();
}

class _TabVivoState extends State<_TabVivo> {
  final otro = TextEditingController();

  @override
  void dispose() {
    otro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final gris = Theme.of(context).hintColor;
    final opciones = [
      if (e.routerIp != null) (n: 'Router (${e.routerIp})', h: e.routerIp!),
      (n: 'Cloudflare 1.1.1.1', h: kHostInternet),
      (n: 'Google 8.8.8.8', h: '8.8.8.8'),
      (n: 'vantaris.es', h: 'vantaris.es'),
    ];
    final ultPing = e.vivoPing.isEmpty ? null : e.vivoPing.last;
    final ultWifi = e.vivoWifi.lastWhere((x) => x != null, orElse: () => null);
    final ultMovil = e.vivoMovil.lastWhere((x) => x != null, orElse: () => null);
    final r = resumirPing(e.vivoHost, e.vivoEnviados, e.vivoPing.whereType<double>().toList());
    final perdidos = e.vivoEnviados - e.vivoRecibidos;

    return ListView(padding: const EdgeInsets.all(16), children: [
      _tarjeta(context, [
        const Text('Ping continuo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Deja esto en marcha y camina por el local: verás al momento dónde baja la señal o se corta la conexión.',
            style: TextStyle(fontSize: 12.5, color: gris)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final o in opciones)
            ChoiceChip(
              label: Text(o.n),
              selected: e.vivoHost == o.h,
              selectedColor: kCoberturaTeal.withOpacity(0.25),
              onSelected: (_) => e.cambiarHostVivo(o.h),
            ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: otro,
              decoration: const InputDecoration(labelText: 'Otro servidor o IP', border: OutlineInputBorder(), isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () {
              final h = otro.text.trim();
              if (h.isNotEmpty) e.cambiarHostVivo(h);
            },
            child: const Text('Usar'),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: e.vivoActivo ? Colors.red : kCoberturaTeal),
            onPressed: e.alternarVivo,
            icon: Icon(e.vivoActivo ? Icons.stop : Icons.play_arrow),
            label: Text(e.vivoActivo ? 'Parar' : 'Empezar'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: e.reiniciarVivo, icon: const Icon(Icons.refresh), label: const Text('Reiniciar')),
        ]),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final tres = c.maxWidth > 700;
        final ancho = tres ? (c.maxWidth - 24) / 3 : c.maxWidth;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: ancho,
            child: _TarjetaVivo('Latencia', e.vivoPing.isEmpty ? '—' : (ultPing != null ? '${fmt(ultPing)} ms' : 'Sin respuesta'),
                ultPing != null ? Capa.latencia.calidad(ultPing) : (e.vivoPing.isEmpty ? null : 0.0), e.vivoHost),
          ),
          SizedBox(
            width: ancho,
            child: _TarjetaVivo('Señal WiFi', ultWifi != null ? '$ultWifi dBm' : '—',
                ultWifi != null ? Capa.wifi.calidad(ultWifi.toDouble()) : null,
                [if (e.vivoSsid != null) e.vivoSsid!, if (e.vivoCanal != null) 'canal ${e.vivoCanal}'].join(' · ').ifEmpty('sin WiFi')),
          ),
          if (e.tieneMovil)
            SizedBox(
              width: ancho,
              child: _TarjetaVivo('Señal móvil', ultMovil != null ? '$ultMovil dBm' : '—',
                  ultMovil != null ? Capa.movil.calidad(ultMovil.toDouble()) : null, 'red de datos'),
            ),
        ]);
      }),
      const SizedBox(height: 12),
      _tarjeta(context, [
        const Text('Latencia (ms)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SizedBox(height: 180, child: _Grafica(e.vivoPing, 0, 200, Capa.latencia, marcarPerdidas: true)),
        const SizedBox(height: 8),
        Wrap(spacing: 18, runSpacing: 6, children: [
          _Dato('Enviados', '${e.vivoEnviados}'),
          _Dato('Perdidos', '$perdidos (${fmt(e.vivoEnviados == 0 ? 0 : perdidos * 100.0 / e.vivoEnviados)} %)'),
          _Dato('Mín.', fmt(r.minMs)),
          _Dato('Media', fmt(r.mediaMs)),
          _Dato('Máx.', fmt(r.maxMs)),
          _Dato('Jitter', fmt(r.jitterMs, 1)),
        ]),
      ]),
      const SizedBox(height: 12),
      _tarjeta(context, [
        const Text('Señal WiFi (dBm)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SizedBox(height: 150, child: _Grafica([for (final v in e.vivoWifi) v?.toDouble()], -95, -30, Capa.wifi)),
        if (e.tieneMovil) ...[
          const SizedBox(height: 12),
          const Text('Señal móvil (dBm)', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SizedBox(height: 150, child: _Grafica([for (final v in e.vivoMovil) v?.toDouble()], -130, -60, Capa.movil)),
        ],
      ]),
      const SizedBox(height: 16),
    ]);
  }
}

extension on String {
  String ifEmpty(String otro) => isEmpty ? otro : this;
}

class _Dato extends StatelessWidget {
  final String t, v;
  const _Dato(this.t, this.v);
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]);
}

class _TarjetaVivo extends StatelessWidget {
  final String titulo, valor, detalle;
  final double? calidad;
  const _TarjetaVivo(this.titulo, this.valor, this.calidad, this.detalle);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = calidad != null ? colorCalidad(calidad!) : t.dividerColor;
    final nivel = calidad != null ? Nivel.de(calidad!) : null;
    return _tarjeta(context, [
      Row(children: [
        Container(width: 6, height: 56, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: TextStyle(color: t.hintColor)),
            Text(valor, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            Text('${nivel != null ? '${nivel.nombre} · ' : ''}$detalle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: nivel != null ? colorNivel(nivel) : t.hintColor)),
          ]),
        ),
      ]),
    ]);
  }
}

/// Línea temporal; los null se marcan como pérdidas (raya roja abajo).
class _Grafica extends StatelessWidget {
  final List<double?> valores;
  final double min, max;
  final Capa capa;
  final bool marcarPerdidas;
  const _Grafica(this.valores, this.min, this.max, this.capa, {this.marcarPerdidas = false});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _GraficaPainter(List.of(valores), min, max, capa, marcarPerdidas, Theme.of(context).dividerColor,
            Theme.of(context).hintColor),
      );
}

class _GraficaPainter extends CustomPainter {
  final List<double?> valores;
  final double min, max;
  final Capa capa;
  final bool marcarPerdidas;
  final Color rejilla, etiqueta;
  _GraficaPainter(this.valores, this.min, this.max, this.capa, this.marcarPerdidas, this.rejilla, this.etiqueta);

  @override
  void paint(Canvas canvas, Size size) {
    const izq = 34.0;
    final w = size.width - izq, h = size.height;
    double y(double v) => h - ((v.clamp(min, max) - min) / (max - min) * h);
    final pr = Paint()
      ..color = rejilla
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = min + (max - min) * i / 4;
      final yy = y(v);
      canvas.drawLine(Offset(izq, yy), Offset(size.width, yy), pr);
      final tp = TextPainter(
          text: TextSpan(text: fmt(v), style: TextStyle(fontSize: 10, color: etiqueta)), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(0, math.max(0.0, math.min(yy - tp.height / 2, h - tp.height))));
    }
    if (valores.isEmpty) return;
    final paso = w / (kMuestrasVivo - 1);
    final x0 = izq + w - (valores.length - 1) * paso;
    final trazo = Paint()
      ..color = _verdeOscuro
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    for (var i = 0; i < valores.length; i++) {
      final x = x0 + i * paso;
      final v = valores[i];
      if (v == null) {
        if (path != null) canvas.drawPath(path, trazo);
        path = null;
        if (marcarPerdidas) {
          canvas.drawLine(Offset(x, h), Offset(x, h - 14), Paint()
            ..color = const Color(0xFFDC2626)
            ..strokeWidth = 3);
        }
      } else {
        final yy = y(v);
        if (path == null) {
          path = Path()..moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
        canvas.drawCircle(Offset(x, yy), 2.6, Paint()..color = colorCalidad(capa.calidad(v)));
      }
    }
    if (path != null) canvas.drawPath(path, trazo);
    final ult = valores.last;
    if (ult != null) {
      canvas.drawCircle(Offset(x0 + (valores.length - 1) * paso, y(ult)), 6, Paint()..color = colorCalidad(capa.calidad(ult)));
    }
  }

  @override
  bool shouldRepaint(_GraficaPainter o) => true;
}

// ======================================================================== Redes

const _coloresRed = [
  Color(0xFF0A7B71), Color(0xFF2563EB), Color(0xFFDB2777), Color(0xFFF59E0B), Color(0xFF7C3AED), //
  Color(0xFF16A34A), Color(0xFFEA580C), Color(0xFF0891B2), Color(0xFFDC2626), Color(0xFF65A30D),
];

Color _colorRed(String ssid) {
  var h = 0;
  for (final c in ssid.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return _coloresRed[h % _coloresRed.length];
}

class _TabRedes extends StatefulWidget {
  final EstadoCobertura e;
  const _TabRedes(this.e);
  @override
  State<_TabRedes> createState() => _TabRedesState();
}

class _TabRedesState extends State<_TabRedes> {
  String banda = 'Todas';
  bool auto = false;

  @override
  void initState() {
    super.initState();
    if (widget.e.redes.isEmpty) widget.e.buscarRedes();
  }

  Future<void> _bucle() async {
    while (auto && mounted) {
      await Future.delayed(const Duration(seconds: 12));
      if (auto && mounted) await widget.e.buscarRedes();
    }
  }

  @override
  void dispose() {
    auto = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final t = Theme.of(context);
    final conectada = e.vivoSsid;
    final filtradas = e.redes.where((r) => banda == 'Todas' || r.banda == banda).toList();
    final canal = Analisis.mejorCanalTexto(e.redes, e.vivoSsid ?? Analisis.redPropia(e.proyecto));
    return ListView(padding: const EdgeInsets.all(16), children: [
      _tarjeta(context, [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Redes WiFi de alrededor', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text('${e.redes.length} puntos de acceso', style: TextStyle(fontSize: 12, color: t.hintColor)),
            ]),
          ),
          if (e.buscandoRedes)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kCoberturaTeal),
            onPressed: e.buscandoRedes ? null : e.buscarRedes,
            icon: const Icon(Icons.search),
            label: const Text('Buscar'),
          ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: auto,
          activeColor: kCoberturaTeal,
          title: const Text('Actualizar sola cada 12 s'),
          onChanged: (v) {
            setState(() => auto = v);
            if (v) _bucle();
          },
        ),
        _chips(const ['Todas', '2,4 GHz', '5 GHz'], banda, (s) => s, (s) => setState(() => banda = s)),
        if (e.errorRedes != null) ...[
          const SizedBox(height: 8),
          Text(e.errorRedes!, style: TextStyle(color: t.colorScheme.error, fontSize: 12.5)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => e.s.abrirAjustes(), icon: const Icon(Icons.settings), label: const Text('Abrir ajustes')),
          ),
        ],
        if (canal != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kCoberturaTeal.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
            child: Text(canal),
          ),
        ],
      ]),
      if (banda != '5 GHz') ...[
        const SizedBox(height: 12),
        _tarjeta(context, [
          const Text('Canales de 2,4 GHz', style: TextStyle(fontWeight: FontWeight.w600)),
          Text('Cada curva es una red. Si muchas se pisan en un canal, ese canal va lento.',
              style: TextStyle(fontSize: 12, color: t.hintColor)),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: CustomPaint(
              size: Size.infinite,
              painter: _CanalesPainter(e.redes.where((r) => r.banda == '2,4 GHz').toList(), conectada, t.dividerColor, t.hintColor),
            ),
          ),
        ]),
      ],
      if (banda != '2,4 GHz' && e.redes.any((r) => r.banda == '5 GHz')) ...[
        const SizedBox(height: 12),
        _tarjeta(context, [
          const Text('Canales de 5 GHz', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: CustomPaint(
              size: Size.infinite,
              painter: _Canales5Painter(e.redes.where((r) => r.banda == '5 GHz').toList(), conectada, t.dividerColor, t.hintColor),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 12),
      _tarjeta(context, padding: const EdgeInsets.symmetric(vertical: 8), [
        for (final r in filtradas) _FilaRed(r, r.ssid == conectada),
        if (filtradas.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Sin redes. Pulsa «Buscar».')),
      ]),
      const SizedBox(height: 16),
    ]);
  }
}

class _FilaRed extends StatelessWidget {
  final RedWifi r;
  final bool conectada;
  const _FilaRed(this.r, this.conectada);

  @override
  Widget build(BuildContext context) {
    final nivel = Capa.wifi.nivel(r.rssi.toDouble());
    final q = Capa.wifi.calidad(r.rssi.toDouble());
    final gris = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: _colorRed(r.ssid), borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r.ssid}${conectada ? '  ·  conectado' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: conectada ? FontWeight.bold : FontWeight.normal)),
            Text('${r.banda} · canal ${r.canal ?? '?'} · ${r.bssid}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
          ]),
        ),
        SizedBox(
          width: 22,
          height: 16,
          child: CustomPaint(painter: _BarrasPainter(q, Theme.of(context).dividerColor)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 72,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${r.rssi} dBm', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(nivel.nombre, style: TextStyle(fontSize: 11, color: colorNivel(nivel))),
          ]),
        ),
      ]),
    );
  }
}

class _BarrasPainter extends CustomPainter {
  final double calidad;
  final Color vacio;
  _BarrasPainter(this.calidad, this.vacio);

  @override
  void paint(Canvas canvas, Size size) {
    const n = 4;
    final llenas = (calidad * n + 0.5).floor().clamp(0, n);
    final bw = size.width / (n * 1.6);
    for (var i = 0; i < n; i++) {
      final bh = size.height * (i + 1) / n;
      canvas.drawRect(Rect.fromLTWH(i * bw * 1.6, size.height - bh, bw, bh),
          Paint()..color = i < llenas ? colorCalidad(calidad) : vacio);
    }
  }

  @override
  bool shouldRepaint(_BarrasPainter o) => o.calidad != calidad;
}

void _texto(Canvas c, String t, Offset o, double tam, Color color, {bool negrita = false, bool centrado = false}) {
  final tp = TextPainter(
    text: TextSpan(text: t, style: TextStyle(fontSize: tam, color: color, fontWeight: negrita ? FontWeight.bold : FontWeight.normal)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, centrado ? o - Offset(tp.width / 2, 0) : o);
}

class _CanalesPainter extends CustomPainter {
  final List<RedWifi> redes;
  final String? conectada;
  final Color rejilla, texto;
  _CanalesPainter(this.redes, this.conectada, this.rejilla, this.texto);

  @override
  void paint(Canvas canvas, Size size) {
    const izq = 30.0, abajo = 18.0;
    final w = size.width - izq, h = size.height - abajo;
    double x(double c) => izq + (c + 1) / 16 * w; // canales -1..15
    double y(int dbm) => h - ((dbm.clamp(-100, -20) + 100) / 80) * h;
    final pr = Paint()..color = rejilla;
    for (var c = 1; c <= 13; c++) {
      canvas.drawLine(Offset(x(c.toDouble()), 0), Offset(x(c.toDouble()), h), pr);
      _texto(canvas, '$c', Offset(x(c.toDouble()), h + 2), 10, texto, negrita: c == 1 || c == 6 || c == 11, centrado: true);
    }
    for (final d in const [-90, -70, -50, -30]) {
      canvas.drawLine(Offset(izq, y(d)), Offset(size.width, y(d)), pr);
      _texto(canvas, '$d', Offset(0, y(d) - 6), 9, texto);
    }
    final orden = [...redes]..sort((a, b) => a.rssi.compareTo(b.rssi));
    for (final r in orden) {
      if (r.canal == null) continue;
      final c = r.canal!.toDouble();
      final col = _colorRed(r.ssid);
      final x0 = x(c - 2), x1 = x(c + 2), xc = x(c), yp = y(r.rssi);
      final p = Path()
        ..moveTo(x0, h)
        ..cubicTo(x0 + (xc - x0) * 0.35, yp, xc - (xc - x0) * 0.35, yp, xc, yp)
        ..cubicTo(xc + (x1 - xc) * 0.35, yp, x1 - (x1 - xc) * 0.35, yp, x1, h);
      canvas.drawPath(p, Paint()..color = col.withOpacity(0.16));
      canvas.drawPath(
          p,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = r.ssid == conectada ? 4 : 2);
      final nombre = r.ssid.length > 16 ? r.ssid.substring(0, 16) : r.ssid;
      _texto(canvas, nombre, Offset(math.max(izq + 30, math.min(xc, size.width - 30)), math.max(0.0, yp - 14)), 9, col, negrita: true, centrado: true);
    }
  }

  @override
  bool shouldRepaint(_CanalesPainter o) => o.redes != redes || o.conectada != conectada;
}

class _Canales5Painter extends CustomPainter {
  final List<RedWifi> redes;
  final String? conectada;
  final Color rejilla, texto;
  _Canales5Painter(this.redes, this.conectada, this.rejilla, this.texto);

  @override
  void paint(Canvas canvas, Size size) {
    final canales = redes.map((r) => r.canal).whereType<int>().toSet().toList()..sort();
    if (canales.isEmpty) return;
    const izq = 30.0, abajo = 18.0;
    final w = size.width - izq, h = size.height - abajo;
    final hueco = w / canales.length;
    double y(int dbm) => h - ((dbm.clamp(-100, -20) + 100) / 80) * h;
    for (final d in const [-90, -70, -50, -30]) {
      canvas.drawLine(Offset(izq, y(d)), Offset(size.width, y(d)), Paint()..color = rejilla);
      _texto(canvas, '$d', Offset(0, y(d) - 6), 9, texto);
    }
    for (var i = 0; i < canales.length; i++) {
      final c = canales[i];
      final cx = izq + hueco * (i + 0.5);
      _texto(canvas, '$c', Offset(cx, h + 2), 10, texto, centrado: true);
      final enCanal = redes.where((r) => r.canal == c).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
      final bw = (hueco * 0.8) / math.max(1, enCanal.length);
      for (var j = 0; j < enCanal.length; j++) {
        final r = enCanal[j];
        final bx = cx - hueco * 0.4 + j * bw;
        canvas.drawRect(Rect.fromLTWH(bx, y(r.rssi), bw * 0.9, h - y(r.rssi)),
            Paint()..color = _colorRed(r.ssid).withOpacity(r.ssid == conectada ? 1 : 0.75));
      }
    }
  }

  @override
  bool shouldRepaint(_Canales5Painter o) => o.redes != redes || o.conectada != conectada;
}

// ======================================================================== Informe

class _TabInforme extends StatelessWidget {
  final EstadoCobertura e;
  const _TabInforme(this.e);

  @override
  Widget build(BuildContext context) {
    final p = e.proyecto;
    final t = Theme.of(context);
    final capas = Capa.values.map((c) => Analisis.resumen(p, c)).where((r) => r.puntos > 0).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      _tarjeta(context, [
        Text(p.nombre, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text('${p.mediciones.length} puntos medidos', style: TextStyle(color: t.hintColor)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kCoberturaTeal),
            onPressed: p.mediciones.isEmpty
                ? null
                : () {
                    final copia = e.proyecto, plano = e.plano, redes = e.redes;
                    _guardar(context, '${nombreArchivo(copia.nombre)}-cobertura.pdf', 'application/pdf',
                        () => informePdf(copia, plano, redes));
                  },
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Informe PDF para el cliente'),
          ),
          FilledButton.tonalIcon(
            onPressed: p.mediciones.isEmpty
                ? null
                : () {
                    final copia = e.proyecto;
                    _guardar(context, '${nombreArchivo(copia.nombre)}.csv', 'text/csv',
                        () async => _utf8('﻿${csvProyecto(copia)}'));
                  },
            icon: const Icon(Icons.table_chart_outlined),
            label: const Text('CSV'),
          ),
          FilledButton.tonalIcon(
            onPressed: () {
              final copia = e.proyecto;
              _guardar(context, '${nombreArchivo(copia.nombre)}.cobertura.json', 'application/json',
                  () async => _utf8(copia.aJson()));
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('Guardar proyecto'),
          ),
        ]),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final ancho = c.maxWidth > 760 ? (c.maxWidth - 24) / 3 : (c.maxWidth > 500 ? (c.maxWidth - 12) / 2 : c.maxWidth);
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final r in capas)
            SizedBox(
              width: ancho,
              child: _tarjeta(context, [
                Text(r.capa.nombre, style: TextStyle(color: t.hintColor)),
                Text('Media ${valorTexto(r.capa, r.media)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text('Peor ${valorTexto(r.capa, r.peor)}${r.peorPunto != null ? ' (punto ${r.peorPunto})' : ''}',
                    style: const TextStyle(fontSize: 12.5)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    height: 10,
                    child: Row(children: [
                      for (final n in Nivel.values)
                        if ((r.porNivel[n] ?? 0) > 0) Expanded(flex: r.porNivel[n]!, child: Container(color: colorNivel(n))),
                    ]),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(spacing: 10, children: [
                  for (final n in Nivel.values)
                    if ((r.porNivel[n] ?? 0) > 0)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        CircleAvatar(radius: 4, backgroundColor: colorNivel(n)),
                        const SizedBox(width: 4),
                        Text('${n.nombre} ${r.porNivel[n]}', style: const TextStyle(fontSize: 11)),
                      ]),
                ]),
              ]),
            ),
        ]);
      }),
      const SizedBox(height: 12),
      _tarjeta(context, [
        const Row(children: [
          Icon(Icons.lightbulb_outline, color: Colors.amber),
          SizedBox(width: 8),
          Text('Recomendaciones', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 10),
        for (final r in Analisis.recomendaciones(p, e.redes))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 7), child: CircleAvatar(radius: 3, backgroundColor: kCoberturaTeal)),
              const SizedBox(width: 10),
              Expanded(child: Text(r)),
            ]),
          ),
      ]),
      const SizedBox(height: 16),
    ]);
  }
}
