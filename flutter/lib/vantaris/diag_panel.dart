// Vantaris: panel de diagnóstico y acciones rápidas en la barra del técnico (Windows).
//
// Pide al equipo (ver diag.dart) sus datos — versión de la app TPV, sistema, batería, espacio,
// red, impresoras y si responden, conexión con el servidor de Vantaris — y deja hacer las
// acciones de la lista cerrada: ticket de prueba en una impresora, abrir el cajón, reiniciar la
// app TPV y traer los registros. Todo lo que se hace pide confirmación y queda escrito en el chat
// de la sesión (lo ve el cliente y entra en el resumen de la asistencia).
//
// «Red del local» (red.dart, sin depender del TPV): ping a una IP, escaneo de la red (qué equipos
// hay y qué son), ticket de prueba y cajón por impresoras de red (9100) y, en equipos Windows, por
// las impresoras instaladas.
//
// Los registros y el diagnóstico se guardan en «Imágenes\Vantaris\registros-<ID>-<fecha>», al lado
// de las capturas, para adjuntarlos al ticket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common.dart' hide Dialog;
import '../models/chat_model.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'diag.dart';
import 'draw.dart';
import 'red.dart';

const _kTeal = Color(0xFF03B5A5);

class VantarisDiagState {
  static final _states = <SessionID, VantarisDiagState>{};

  static VantarisDiagState of(FFI ffi) =>
      _states.putIfAbsent(ffi.sessionId, () => VantarisDiagState._(ffi));

  static VantarisDiagState? find(SessionID sessionId) => _states[sessionId];

  static void disposeFor(SessionID sessionId) => _states.remove(sessionId)?._dispose();

  VantarisDiagState._(this.ffi);

  final FFI ffi;
  final _asm = VantarisDiagAssembler();
  final _waiting = <String, Completer<Map<String, dynamic>>>{};
  final _rand = Random();

  final RxBool open = false.obs;
  final RxBool loading = false.obs;
  final Rx<Map<String, dynamic>?> estado = Rx<Map<String, dynamic>?>(null);
  final RxString busy = ''.obs; // acción en curso (texto para el usuario)
  final RxString last = ''.obs; // resultado de la última acción
  final RxString progress = ''.obs;
  final Rx<Map<String, dynamic>?> red = Rx<Map<String, dynamic>?>(null); // último escaneo
  final Rx<List?> impresorasWin = Rx<List?>(null);
  String? lastFolder;

  SessionID get _sid => ffi.sessionId;

  /// Petición al equipo; devuelve su JSON (o un error con «motivo»).
  Future<Map<String, dynamic>> request(String orden, {String? arg, Duration? timeout}) async {
    final rid = _rand.nextInt(1 << 30).toRadixString(36);
    final c = Completer<Map<String, dynamic>>();
    _waiting[rid] = c;
    final line = arg == null ? 'Q $rid $orden' : 'Q $rid $orden $arg';
    bind.sessionSendChat(sessionId: _sid, text: kVantarisDrawPrefix + line);
    Timer? tick;
    tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final p = _asm.progress(rid);
      progress.value = p == null ? '' : '${(p.$1 * 100 / p.$2).round()} %';
    });
    try {
      return await c.future.timeout(timeout ?? const Duration(seconds: 40));
    } on TimeoutException {
      _asm.forget(rid);
      return {'ok': false, 'motivo': 'El equipo no ha contestado a tiempo.'};
    } finally {
      tick.cancel();
      progress.value = '';
      _waiting.remove(rid);
    }
  }

  void onPeerLine(String line) {
    final r = _asm.add(line);
    if (r == null) return;
    final c = _waiting[r.$1];
    if (c != null && !c.isCompleted) c.complete(r.$2);
  }

  Future<void> toggle(BuildContext context) async {
    if (open.value) return;
    final ok = await vantarisPeerSupportsDraw(_sid);
    if (!ok || !vantarisPeerHas(_sid, 'diag')) {
      showToast('Este equipo no tiene la versión de «Vantaris Soporte» con diagnóstico.',
          timeout: const Duration(seconds: 5));
      return;
    }
    open.value = true;
    refresh();
    await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) => _DiagDialog(state: this));
    open.value = false;
  }

  Future<void> refresh() async {
    if (loading.value) return;
    loading.value = true;
    estado.value = await request('estado');
    loading.value = false;
  }

  /// Escribe lo hecho en el chat de la sesión (lo ve el cliente y entra en el resumen).
  void logChat(String text) {
    final msg = '[Soporte Vantaris] $text';
    bind.sessionSendChat(sessionId: _sid, text: msg);
    try {
      ffi.chatModel.insertMessage(MessageKey(ffi.id, ChatModel.clientModeID),
          ChatMessage(text: msg, user: ffi.chatModel.me, createdAt: DateTime.now()));
    } catch (_) {}
  }

  Future<void> action(String orden, String what, {String? arg}) async {
    if (busy.value.isNotEmpty) return;
    busy.value = what;
    last.value = '';
    final r = await request(orden, arg: arg, timeout: const Duration(seconds: 45));
    busy.value = '';
    final ok = r['ok'] == true;
    final text = ok ? (r['mensaje'] ?? 'Hecho.') : (r['motivo'] ?? 'No se ha podido.');
    last.value = '${ok ? '✓' : '✗'} $text';
    logChat('$what: ${ok ? 'hecho' : 'no se ha podido'}. $text');
    if (orden == 'reiniciar' && ok) {
      Timer(const Duration(seconds: 8), refresh);
    }
  }

  /// Escanea la red del local desde el equipo (tarda 15-40 s).
  Future<void> escanear() async {
    if (busy.value.isNotEmpty) return;
    busy.value = 'Escaneando la red del local';
    last.value = '';
    logChat('Escaneo de la red del local para ver qué equipos hay conectados.');
    final r = await request('red', timeout: const Duration(seconds: 90));
    busy.value = '';
    if (r['ok'] == true) {
      red.value = r;
      final e = estado.value;
      if (e != null) estado.value = {...e, 'red': r}; // para el diagnóstico que va al ticket
      last.value = '✓ ${r['mensaje']}';
    } else {
      last.value = '✗ ${r['motivo'] ?? 'No se ha podido escanear.'}';
    }
  }

  /// Impresoras instaladas en el Windows del equipo.
  Future<void> cargarImpresorasWin() async {
    if (busy.value.isNotEmpty) return;
    busy.value = 'Leyendo las impresoras de Windows';
    final r = await request('impresoras');
    busy.value = '';
    if (r['ok'] == true) {
      impresorasWin.value = (r['impresoras'] as List?) ?? [];
      last.value = '✓ ${r['mensaje']}';
    } else {
      last.value = '✗ ${r['motivo'] ?? 'No se han podido leer.'}';
    }
  }

  /// Trae los registros del TPV y los guarda junto al diagnóstico en el PC del técnico.
  Future<void> fetchLogs() async {
    if (busy.value.isNotEmpty) return;
    busy.value = 'Trayendo registros';
    last.value = '';
    final r = await request('registros', timeout: const Duration(minutes: 5));
    busy.value = '';
    if (r['ok'] != true) {
      last.value = '✗ ${r['motivo'] ?? 'No se han podido traer los registros.'}';
      return;
    }
    try {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      final sep = Platform.pathSeparator;
      final dir = Directory('$home${sep}Pictures${sep}Vantaris${sep}registros-${ffi.id}-$stamp');
      await dir.create(recursive: true);
      var n = 0, bytes = 0;
      for (final a in (r['arranques'] as List? ?? [])) {
        final m = a as Map;
        final gz = m['gz'] as String?;
        if (gz == null) continue;
        final raw = gzip.decode(base64.decode(gz));
        final ini = DateTime.fromMillisecondsSinceEpoch((m['inicio'] as num?)?.toInt() ?? 0);
        final name = 'tpv-${ini.year}${two(ini.month)}${two(ini.day)}-${two(ini.hour)}${two(ini.minute)}'
            '${m['actual'] == true ? '-actual' : ''}-${m['id']}.log';
        await File('${dir.path}$sep$name').writeAsBytes(raw, flush: true);
        n++;
        bytes += raw.length;
      }
      final e = estado.value;
      if (e != null) {
        await File('${dir.path}${sep}diagnostico.txt')
            .writeAsString(vantarisDiagText(e, ffi.id), flush: true);
      }
      lastFolder = dir.path;
      last.value = n == 0
          ? '✓ El TPV no tiene registros guardados todavía.'
          : '✓ $n registros (${(bytes / 1024).round()} KB) en ${dir.path}';
      logChat('Registros del TPV descargados para el ticket ($n ficheros).');
    } catch (e) {
      last.value = '✗ No se han podido guardar: $e';
    }
  }

  void _dispose() {
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.complete({'ok': false, 'motivo': 'Sesión cerrada.'});
    }
    _waiting.clear();
  }
}

/// Línea «q …» del equipo para el técnico.
void vantarisDiagFromPeer(SessionID sessionId, String body) =>
    VantarisDiagState.find(sessionId)?.onPeerLine(body);

// ---------------------------------------------------------------- texto (para el ticket)

String _mb(dynamic v) {
  final n = (v as num?)?.toDouble();
  if (n == null || n < 0) return '—';
  return n >= 1024 ? '${(n / 1024).toStringAsFixed(1)} GB' : '${n.round()} MB';
}

String _yesNo(dynamic v) => v == true ? 'sí' : (v == false ? 'no' : '—');

List<(String, String)> _equipoRows(Map<String, dynamic> e) {
  final eq = (e['equipo'] as Map?)?.cast<String, dynamic>() ?? {};
  final bat = eq['bateria'];
  String bateria;
  if (bat == null || (bat as num) < 0) {
    bateria = eq['sinBateria'] == true ? 'sin batería (a la corriente)' : '—';
  } else {
    bateria = '${bat.round()} %${eq['cargando'] == true ? ', cargando' : ''}'
        '${eq['enchufado'] == true && eq['cargando'] != true ? ', enchufado' : ''}';
  }
  final red = eq['red'] as Map?;
  var redTxt = '—';
  if (red != null) {
    final tipo = red['tipo'] ?? '—';
    redTxt = '$tipo${red['ip'] != null ? ' · IP ${red['ip']}' : ''}'
        '${red['senal'] != null ? ' · señal ${red['senal']} dBm' : ''}';
  }
  return [
    ('Sistema', '${eq['so'] ?? '—'}'),
    if (eq['modelo'] != null) ('Modelo', '${eq['modelo']}'),
    ('Batería', bateria),
    ('Espacio libre', '${_mb(eq['discoLibreMb'])} de ${_mb(eq['discoTotalMb'])}'),
    ('Memoria libre', '${_mb(eq['memLibreMb'])} de ${_mb(eq['memTotalMb'])}'),
    ('Red', redTxt),
  ];
}

String _servidorTxt(Map<String, dynamic> e) {
  final s = (e['servidor'] as Map?) ?? {};
  final t = (e['tpv'] as Map?) ?? {};
  final llega = s['llega'] == true
      ? 'El equipo llega a ${s['host']} (${s['ms']} ms)'
      : 'El equipo NO llega a ${s['host'] ?? 'api.vantaris.es'}';
  final ws = t['servidor'];
  final wsTxt = ws == null
      ? ''
      : t['enMarcha'] == false
          ? ' · el TPV no está conectado (la app no está abierta)'
          : ws == 'CONNECTED'
          ? ' · TPV conectado al servidor'
          : (t['rol'] == 'SECUNDARIO'
              ? ' · TPV secundario (habla con el servidor a través del principal)'
              : ' · TPV SIN conexión con el servidor ($ws)');
  return '$llega$wsTxt';
}

List<(String, String)> _tpvRows(Map<String, dynamic> e) {
  final t = (e['tpv'] as Map?)?.cast<String, dynamic>() ?? {};
  if (t['instalado'] == false) return [('App TPV', 'no instalada en este equipo')];
  final rows = <(String, String)>[];
  final version = t['version'] ?? t['versionInstalada'];
  if (version != null) {
    rows.add(('Versión TPV', '$version${t['entorno'] != null && t['entorno'] != 'PRODUCCION' ? ' (${t['entorno']})' : ''}'));
  }
  if (t['ok'] != true) {
    rows.add(('Estado', '${t['motivo'] ?? 'sin respuesta del TPV'}'));
    return rows;
  }
  rows.add(('Abierta', t['abierta'] == false ? 'no (la pantalla del TPV está cerrada)' : _yesNo(t['abierta'])));
  if (t['enMarcha'] == false) {
    rows.add(('Red del local', 'parada (la app no está abierta)'));
  } else if (t['rol'] != null) {
    rows.add(('Papel en el local', t['rol'] == 'PRINCIPAL' ? 'TPV principal' : 'TPV secundario'));
  }
  if (t['vinculado'] != null) rows.add(('Vinculado a Vantaris', _yesNo(t['vinculado'])));
  final eq = (t['equipos'] as List?) ?? [];
  if (eq.isNotEmpty) {
    rows.add(('Conectados', eq.map((d) => '${(d as Map)['nombre']}').join(', ')));
  }
  return rows;
}

String _impresoraEstado(Map p) {
  if (p['activa'] == false) return 'desactivada';
  if (p['responde'] == true) return 'responde';
  if (p['responde'] == false) return 'NO responde';
  return 'sin comprobar';
}

/// El diagnóstico como texto, para el fichero que va al ticket.
String vantarisDiagText(Map<String, dynamic> e, String peerId) {
  final b = StringBuffer();
  b.writeln('Diagnóstico Vantaris · equipo $peerId · ${DateTime.now()}');
  b.writeln('');
  for (final r in _equipoRows(e)) {
    b.writeln('${r.$1}: ${r.$2}');
  }
  b.writeln('Servidor: ${_servidorTxt(e)}');
  b.writeln('');
  for (final r in _tpvRows(e)) {
    b.writeln('${r.$1}: ${r.$2}');
  }
  final imps = ((e['tpv'] as Map?)?['impresoras'] as List?) ?? [];
  if (imps.isNotEmpty) b.writeln('Impresoras:');
  for (final p in imps) {
    final m = p as Map;
    b.writeln('  - ${m['nombre']} (${m['tipo']}, ${m['conexion']} ${m['direccion']})'
        '${m['cajon'] == true ? ' [cajón]' : ''}: ${_impresoraEstado(m)}');
  }
  final red = e['red'] as Map?;
  if (red != null) {
    b.writeln('');
    b.writeln('Red del local (${(red['redes'] as List?)?.join(', ')}):');
    for (final q in (red['equipos'] as List? ?? [])) {
      b.writeln('  - ${_equipoRed(q as Map)}');
    }
  }
  return b.toString();
}

String _equipoRed(Map q) => [
      q['ip'],
      q['nombre'],
      q['fabricante'],
      q['tipo'],
      q['modelo'],
      q['so'],
      if ((q['puertos'] as List?)?.isNotEmpty == true) 'puertos ${(q['puertos'] as List).join(',')}',
    ].where((v) => v != null && '$v'.isNotEmpty).join(' · ');

IconData _iconoTipo(String? tipo) {
  final t = tipo ?? '';
  if (t.startsWith('impresora')) return Icons.print_outlined;
  if (t.startsWith('router')) return Icons.router_outlined;
  if (t.startsWith('ordenador')) return Icons.computer;
  if (t.startsWith('datáfono')) return Icons.credit_card;
  if (t.startsWith('TPV')) return Icons.point_of_sale;
  if (t.startsWith('cámara')) return Icons.videocam_outlined;
  if (t.contains('móvil') || t.startsWith('iPhone') || t.startsWith('Android')) return Icons.smartphone;
  if (t.contains('Linux')) return Icons.dns_outlined;
  return Icons.device_unknown_outlined;
}

// ---------------------------------------------------------------- panel

class _DiagDialog extends StatelessWidget {
  final VantarisDiagState state;
  const _DiagDialog({required this.state});

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
                  title: Text(title),
                  content: Text(body),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                    FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _kTeal),
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Sí, hacerlo')),
                  ],
                )) ??
        false;
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, color: _kTeal, fontSize: 13)),
          const SizedBox(height: 6),
          ...children,
        ]),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.grey))),
          Expanded(child: SelectableText(v)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Obx(() {
            final e = state.estado.value;
            final t = (e?['tpv'] as Map?)?.cast<String, dynamic>() ?? {};
            final tpvOk = t['ok'] == true;
            final imps = (t['impresoras'] as List?) ?? [];
            final cajon = imps.any((p) => (p as Map)['cajon'] == true && p['activa'] != false);
            final busy = state.busy.value;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.medical_services_outlined, color: _kTeal),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('Diagnóstico del equipo',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                IconButton(
                    tooltip: 'Volver a comprobar',
                    onPressed: state.loading.value ? null : state.refresh,
                    icon: const Icon(Icons.refresh)),
                IconButton(
                    tooltip: 'Cerrar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close)),
              ]),
              if (state.loading.value) const LinearProgressIndicator(color: _kTeal),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (e == null && state.loading.value)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Preguntando al equipo…', textAlign: TextAlign.center)),
                    if (e != null && e['ok'] != true && e['equipo'] == null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text('${e['motivo'] ?? 'El equipo no ha contestado.'}',
                              style: const TextStyle(color: Colors.red))),
                    if (e != null && e['equipo'] != null) ...[
                      _section('Equipo', [for (final r in _equipoRows(e)) _row(r.$1, r.$2)]),
                      _section('Servidor de Vantaris', [Text(_servidorTxt(e))]),
                      _section('App TPV Vantaris', [for (final r in _tpvRows(e)) _row(r.$1, r.$2)]),
                      if (tpvOk)
                        _section('Impresoras', [
                          if (imps.isEmpty) const Text('No hay impresoras configuradas en el TPV.'),
                          for (final p in imps) _printerRow(context, p as Map, busy.isEmpty),
                        ]),
                      _section('Red del local', [
                        if (!vantarisPeerHas(state.ffi.sessionId, 'red'))
                          const Text('El equipo tiene una versión de Vantaris Soporte sin estas pruebas: '
                              'hay que actualizarla.')
                        else
                          ..._redSection(context, e, busy.isEmpty),
                      ]),
                    ],
                  ]),
                ),
              ),
              const Divider(height: 24),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Traer registros'),
                  onPressed: busy.isEmpty && tpvOk ? state.fetchLogs : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Abrir cajón'),
                  onPressed: busy.isEmpty && tpvOk && cajon
                      ? () async {
                          if (await _confirm(context, 'Abrir el cajón',
                              '¿Abrir el cajón portamonedas del cliente? Se abrirá de verdad.')) {
                            state.action('cajon', 'Apertura del cajón portamonedas');
                          }
                        }
                      : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reiniciar la app TPV'),
                  onPressed: busy.isEmpty && tpvOk
                      ? () async {
                          if (await _confirm(context, 'Reiniciar la app TPV',
                              'La app TPV se cerrará y volverá a abrirse (unos segundos). '
                                  'Lo que no esté guardado, como un cobro a medias, se pierde. '
                                  'Avisa al cliente antes. ¿Seguimos?')) {
                            state.action('reiniciar', 'Reinicio de la app TPV');
                          }
                        }
                      : null,
                ),
                if (state.lastFolder != null)
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Abrir carpeta'),
                    onPressed: () => Process.run('explorer.exe', [state.lastFolder!]),
                  ),
              ]),
              if (busy.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(children: [
                      const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text('$busy… ${state.progress.value}'),
                    ])),
              if (state.last.value.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SelectableText(state.last.value,
                        style: TextStyle(
                            color: state.last.value.startsWith('✓') ? Colors.green[700] : Colors.red))),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _printerRow(BuildContext context, Map p, bool enabled) {
    final est = _impresoraEstado(p);
    final color = est == 'responde'
        ? Colors.green
        : est == 'NO responde'
            ? Colors.red
            : Colors.grey;
    final tipo = p['tipo'] == 'COCINA' ? 'cocina/barra' : 'tickets';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 8),
        Expanded(
            child: Text('${p['nombre']} · $tipo · ${p['conexion']} ${p['direccion']}'
                '${p['cajon'] == true ? ' · cajón' : ''} — $est')),
        TextButton(
          onPressed: enabled && p['activa'] != false
              ? () async {
                  if (await _confirm(context, 'Ticket de prueba',
                      'Se imprimirá un ticket de prueba en «${p['nombre']}». ¿Seguimos?')) {
                    state.action('prueba', 'Ticket de prueba en «${p['nombre']}»',
                        arg: '${p['id']}');
                  }
                }
              : null,
          child: const Text('Imprimir prueba'),
        ),
      ]),
    );
  }

  List<Widget> _redSection(BuildContext context, Map<String, dynamic> e, bool enabled) {
    final red = state.red.value;
    final esWindows = e['plataforma'] == 'windows';
    final winImps = state.impresorasWin.value;
    return [
      _PingField(state: state, enabled: enabled),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.radar),
          label: Text(red == null ? 'Escanear red' : 'Volver a escanear'),
          onPressed: enabled ? state.escanear : null,
        ),
        if (esWindows)
          OutlinedButton.icon(
            icon: const Icon(Icons.print_outlined),
            label: const Text('Impresoras de Windows'),
            onPressed: enabled ? state.cargarImpresorasWin : null,
          ),
      ]),
      if (red != null) ...[
        const SizedBox(height: 8),
        Text('${red['mensaje']} (${red['segundos']} s). Lo marcado «estimado» se deduce, no es seguro.',
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        for (final q in (red['equipos'] as List? ?? [])) _equipoRow(context, q as Map, enabled),
      ],
      if (winImps != null) ...[
        const SizedBox(height: 8),
        const Text('Impresoras instaladas en Windows (la prueba y el cajón solo valen para las de tickets):',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        if (winImps.isEmpty) const Text('Ninguna.'),
        for (final p in winImps) _winPrinterRow(context, p as Map, enabled),
      ],
    ];
  }

  Widget _equipoRow(BuildContext context, Map q, bool enabled) {
    final ip = '${q['ip']}';
    final con9100 = (q['puertos'] as List?)?.contains(9100) == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(_iconoTipo(q['tipo'] as String?), size: 18, color: _kTeal)),
        Expanded(child: SelectableText(_equipoRed(q))),
        TextButton(
            onPressed: enabled ? () => state.action('ping', 'Ping a $ip', arg: ip) : null,
            child: const Text('Ping')),
        // Prueba y cajón solo por el puerto 9100 (ESC/POS en crudo, el de las impresoras de tickets).
        if (con9100) ...[
          TextButton(
            onPressed: enabled
                ? () async {
                    if (await _confirm(context, 'Ticket de prueba',
                        'Se imprimirá un ticket de prueba en la impresora $ip. ¿Seguimos?')) {
                      state.action('imprimirip', 'Ticket de prueba en la impresora $ip', arg: ip);
                    }
                  }
                : null,
            child: const Text('Imprimir prueba'),
          ),
          TextButton(
            onPressed: enabled
                ? () async {
                    if (await _confirm(context, 'Abrir el cajón',
                        '¿Abrir el cajón conectado a la impresora $ip? Se abrirá de verdad.')) {
                      state.action('cajonip', 'Apertura del cajón por la impresora $ip', arg: ip);
                    }
                  }
                : null,
            child: const Text('Abrir cajón'),
          ),
        ],
      ]),
    );
  }

  Widget _winPrinterRow(BuildContext context, Map p, bool enabled) {
    final nombre = '${p['nombre']}';
    final n = '${p['n']}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        const Padding(
            padding: EdgeInsets.only(right: 8), child: Icon(Icons.print_outlined, size: 18, color: _kTeal)),
        Expanded(
            child: SelectableText('$nombre · ${p['puerto']} · ${p['driver']}'
                '${p['predeterminada'] == true ? ' · predeterminada' : ''}')),
        TextButton(
          onPressed: enabled
              ? () async {
                  if (await _confirm(context, 'Ticket de prueba',
                      'Se imprimirá un ticket de prueba en «$nombre». Si no es una impresora de '
                          'tickets puede salir texto raro. ¿Seguimos?')) {
                    state.action('imprimirlocal', 'Ticket de prueba en «$nombre»', arg: n);
                  }
                }
              : null,
          child: const Text('Imprimir prueba'),
        ),
        TextButton(
          onPressed: enabled
              ? () async {
                  if (await _confirm(context, 'Abrir el cajón',
                      '¿Abrir el cajón conectado a «$nombre»? Se abrirá de verdad.')) {
                    state.action('cajonlocal', 'Apertura del cajón por «$nombre»', arg: n);
                  }
                }
              : null,
          child: const Text('Abrir cajón'),
        ),
      ]),
    );
  }
}

/// Campo para hacer ping a una IP de la red del local.
class _PingField extends StatefulWidget {
  final VantarisDiagState state;
  final bool enabled;
  const _PingField({required this.state, required this.enabled});

  @override
  State<_PingField> createState() => _PingFieldState();
}

class _PingFieldState extends State<_PingField> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _ping() {
    final ip = _ctl.text.trim();
    if (!vantarisIpPrivada(ip)) {
      showToast('Pon una IP de la red del local (por ejemplo 192.168.1.50).');
      return;
    }
    widget.state.action('ping', 'Ping a $ip', arg: ip);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _ctl,
          enabled: widget.enabled,
          decoration: const InputDecoration(
              isDense: true, hintText: 'IP de un equipo del local (p. ej. 192.168.1.50)'),
          onSubmitted: (_) => _ping(),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
          icon: const Icon(Icons.network_ping),
          label: const Text('Ping'),
          onPressed: widget.enabled ? _ping : null),
    ]);
  }
}
