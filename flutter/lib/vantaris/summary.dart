// Vantaris: resumen automático de la asistencia (lado técnico, Windows).
//
// El técnico pulsa «Grabar para el resumen»: el runner graba dos pistas (su micrófono y lo que
// suena en su equipo, que es donde llega la voz del cliente por la llamada; ver
// windows/runner/vantaris_audio.cpp). Al parar, se suben con el chat de la sesión al servicio de
// resumen (RemoteControl/servicios/resumen-sesion, en Esclavito): Whisper + LLM local. El texto
// vuelve en un diálogo para copiarlo al ticket de Falcon.
//
// Mientras se graba, junto al botón hay un medidor con el nivel de las dos pistas. Si el micro
// del técnico lleva 5 s en silencio absoluto (ceros: casco apagado o silenciado, entrada
// equivocada…) sale un aviso con el micrófono en uso y la lista para cambiarlo sin parar la
// grabación. El elegido se guarda en la opción local «vantaris-mic-id».
// Al parar: si ha durado menos de 10 s o no se ha oído nada, no se sube; se ofrece descartar.
//
// El cliente ve que se graba: «R 1» / «R 0» por el canal de la pizarra (Android lo pone en el
// aviso de arriba; Windows, en la capa del runner).
//
// URL del servicio: variable de entorno VANTARIS_RESUMEN_URL, o la opción local
// «vantaris-resumen-url», o la que se fije al compilar con --dart-define=VANTARIS_RESUMEN_URL
// (build-vantaris.sh). El código no lleva ninguna dirección interna: sin configurar, avisa de
// que el servicio no responde y deja guardar el audio.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../common.dart';
import '../models/chat_model.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'draw.dart';

const _channel = MethodChannel('es.vantaris/tecnico');
const _kDefaultUrl = String.fromEnvironment('VANTARIS_RESUMEN_URL');
const kVantarisMicOption = 'vantaris-mic-id';

/// Por debajo de esto el WAV de 16 bits es cero: silencio digital, no «habla bajito».
const _kZero = 1 / 32768;
const _kSilenceWarn = Duration(seconds: 5);
const _kMinSeconds = 10;
const _kPoll = Duration(milliseconds: 150);

String vantarisSummaryUrl() {
  final env = Platform.environment['VANTARIS_RESUMEN_URL'];
  if (env != null && env.isNotEmpty) return env;
  final opt = bind.mainGetLocalOption(key: 'vantaris-resumen-url');
  return opt.isNotEmpty ? opt : _kDefaultUrl;
}

void _log(String msg) {
  if (Platform.environment['VANTARIS_DEMO'] != '1') return;
  try {
    final tmp = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    File('$tmp${Platform.pathSeparator}vantaris-demo.log')
        .writeAsStringSync('${DateTime.now()} resumen: $msg\n', mode: FileMode.append);
  } catch (_) {}
}

class VantarisAudioInput {
  final String id;
  final String name;
  final bool isDefault;
  VantarisAudioInput(this.id, this.name, this.isDefault);
}

Future<List<VantarisAudioInput>> vantarisAudioInputs() async {
  try {
    final list = await _channel.invokeMethod<List<dynamic>>('audioInputs') ?? [];
    return list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return VantarisAudioInput(
          '${m['id']}', '${m['name']}', m['default'] == true);
    }).toList();
  } catch (_) {
    return [];
  }
}

class VantarisSummaryState {
  static final _states = <SessionID, VantarisSummaryState>{};

  static VantarisSummaryState of(FFI ffi) =>
      _states.putIfAbsent(ffi.sessionId, () => VantarisSummaryState._(ffi));

  /// Al cerrar la sesión: si se estaba grabando, se para y se resume igualmente.
  static void disposeFor(SessionID sessionId) {
    final s = _states.remove(sessionId);
    if (s != null && s.recording.isTrue) s._stopAndSummarize(peerGone: true);
  }

  VantarisSummaryState._(this.ffi);

  final FFI ffi;
  final RxBool recording = false.obs;
  final RxBool busy = false.obs;

  // Medidor (0..1, escala logarítmica) y estado del micrófono.
  final RxDouble micLevel = 0.0.obs;
  final RxDouble eqLevel = 0.0.obs;
  final RxString micName = ''.obs;
  final RxString eqName = ''.obs;
  final RxBool micSilent = false.obs; // lleva 5 s o más dando ceros
  final RxBool micBroken = false.obs; // no se pudo abrir / se ha perdido
  final RxInt seconds = 0.obs;

  DateTime? _since;
  DateTime _micSoundAt = DateTime.now(); // último sonido del micro (o arranque/cambio)
  bool _warned = false;
  bool _dialogOpen = false;
  double _micMax = 0, _eqMax = 0, _duration = 0;
  Timer? _heartbeat; // repite «R 1»: si el técnico desaparece, el aviso se quita solo
  Timer? _poll;

  bool get available => isWindows;

  Future<void> toggle() async {
    if (busy.isTrue) return;
    if (recording.isTrue) {
      await _stopAndSummarize();
      return;
    }
    busy.value = true;
    try {
      final ok = await _channel.invokeMethod<bool>('audioStart', {
            'dir': Directory.systemTemp.path,
            'mic': await _savedMic(),
          }) ??
          false;
      if (!ok) {
        showToast('No se pudo empezar a grabar (¿hay micrófono o altavoces?).');
        return;
      }
      recording.value = true;
      _since = DateTime.now();
      _micSoundAt = _since!;
      _warned = false;
      _micMax = _eqMax = 0;
      micSilent.value = micBroken.value = false;
      micLevel.value = eqLevel.value = 0;
      seconds.value = 0;
      _notifyPeer(true);
      _heartbeat = Timer.periodic(const Duration(seconds: 6), (_) => _notifyPeer(true));
      _poll = Timer.periodic(_kPoll, (_) => _refresh());
      showToast('Grabando la asistencia para el resumen. El cliente ve el aviso.');
      _checkService();
    } catch (e) {
      showToast('No se pudo empezar a grabar: $e');
    } finally {
      busy.value = false;
    }
  }

  /// Micrófono guardado, si sigue conectado (si no, el predeterminado de Windows).
  Future<String> _savedMic() async {
    final id = bind.mainGetLocalOption(key: kVantarisMicOption);
    if (id.isEmpty) return '';
    final inputs = await vantarisAudioInputs();
    return inputs.any((i) => i.id == id) ? id : '';
  }

  /// Aviso temprano: mejor saber al empezar que el servicio no está que enterarse al final.
  Future<void> _checkService() async {
    final url = vantarisSummaryUrl();
    try {
      final r = await http.get(Uri.parse('$url/salud')).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) return;
    } catch (_) {}
    _log('el servicio no responde en $url');
    showToast('Ojo: el servicio de resumen no responde ($url). Se graba igualmente y al '
        'final podrás guardar el audio.', timeout: const Duration(seconds: 8));
  }

  static double _toLevel(double peak) {
    if (peak < _kZero) return 0;
    final db = 20 * math.log(peak) / math.ln10; // -90..0
    return ((db + 60) / 60).clamp(0.02, 1.0);
  }

  Future<void> _refresh() async {
    if (recording.isFalse) return;
    Map<String, dynamic> st;
    try {
      st = Map<String, dynamic>.from(await _channel.invokeMethod('audioStatus') as Map);
    } catch (_) {
      return;
    }
    if (recording.isFalse) return;
    final tracks = (st['tracks'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final mic = tracks[0], eq = tracks[1];
    final micPeak = (mic['peak'] as num).toDouble();
    final eqPeak = (eq['peak'] as num).toDouble();
    // Subida inmediata, bajada suave.
    micLevel.value = math.max(_toLevel(micPeak), micLevel.value * 0.75);
    eqLevel.value = math.max(_toLevel(eqPeak), eqLevel.value * 0.75);
    micName.value = '${mic['name']}';
    eqName.value = '${eq['name']}';
    micBroken.value = (mic['state'] as int) < 0;
    _micMax = math.max(_micMax, (mic['max'] as num).toDouble());
    _eqMax = math.max(_eqMax, (eq['max'] as num).toDouble());
    _duration = (st['seconds'] as num).toDouble();
    seconds.value = _duration.floor();
    final now = DateTime.now();
    if (micPeak >= _kZero) _micSoundAt = now;
    micSilent.value = now.difference(_micSoundAt) >= _kSilenceWarn;
    if (micSilent.isTrue && !_warned && !_dialogOpen) {
      _warned = true;
      _log('micro en silencio: «${micName.value}» (estado ${mic['state']})');
      showMicDialog(warning: true);
    }
  }

  /// Diálogo del micrófono: aviso de silencio (warning) o elegir otro desde el medidor.
  Future<void> showMicDialog({bool warning = false}) async {
    if (_dialogOpen) return;
    final inputs = await vantarisAudioInputs();
    final saved = bind.mainGetLocalOption(key: kVantarisMicOption);
    String? selected = inputs.any((i) => i.id == saved)
        ? saved
        : inputs.firstWhereOrNull((i) => i.isDefault)?.id;
    _dialogOpen = true;
    try {
      await ffi.dialogManager.show((setState, close, context) {
        final muted = TextStyle(color: Theme.of(context).hintColor, fontSize: 13);
        return CustomAlertDialog(
          title: Row(children: [
            Icon(warning ? Icons.mic_off : Icons.mic,
                color: warning ? Colors.orange : null),
            const SizedBox(width: 8),
            Expanded(
                child: Text(warning
                    ? 'Tu micrófono no capta nada'
                    : 'Micrófono para el resumen')),
          ]),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (warning) ...[
                  const Text('Llevas unos segundos grabando y de tu micrófono no llega ningún '
                      'sonido: tu voz no saldrá en el resumen.'),
                  const SizedBox(height: 6),
                  Text('Revisa en Windows cuál es la entrada por defecto, que el casco esté '
                      'encendido y que el micro no esté silenciado (botón del casco o brazo '
                      'levantado). O elige aquí otro micrófono: la grabación sigue.',
                      style: muted),
                  const SizedBox(height: 10),
                ],
                Text('Ahora se usa: ${micName.value.isEmpty ? '(ninguno)' : micName.value}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (inputs.isEmpty)
                  Text('Windows no tiene ningún micrófono activo.', style: muted)
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: Column(
                        children: inputs
                            .map((i) => RadioListTile<String>(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: i.id,
                                  groupValue: selected,
                                  onChanged: (v) => setState(() => selected = v),
                                  title: Text(i.name),
                                  subtitle: i.isDefault
                                      ? const Text('Predeterminado de Windows')
                                      : null,
                                ))
                            .toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            dialogButton('Ajustes de sonido', isOutline: true, onPressed: () {
              launchUrl(Uri.parse('ms-settings:sound'));
            }),
            dialogButton(warning ? 'Seguir así' : 'Cancelar',
                isOutline: true, onPressed: close),
            dialogButton('Usar este micrófono', onPressed: selected == null
                ? null
                : () {
                    close();
                    _useMic(inputs.firstWhere((i) => i.id == selected));
                  }),
          ],
          onCancel: close,
        );
      });
    } catch (_) {
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _useMic(VantarisAudioInput input) async {
    // El predeterminado se guarda vacío: así sigue a Windows si allí se cambia.
    await bind.mainSetLocalOption(
        key: kVantarisMicOption, value: input.isDefault ? '' : input.id);
    if (recording.isTrue) {
      try {
        await _channel.invokeMethod('audioSetMic', input.isDefault ? '' : input.id);
      } catch (_) {}
      _micSoundAt = DateTime.now();
      _warned = false; // si el nuevo tampoco capta nada, se vuelve a avisar
      micSilent.value = false;
    }
    _log('micro elegido: «${input.name}»');
    showToast('Micrófono: ${input.name}');
  }

  void _notifyPeer(bool on) {
    try {
      bind.sessionSendChat(
          sessionId: ffi.sessionId, text: '${kVantarisDrawPrefix}R ${on ? 1 : 0}');
    } catch (_) {}
  }

  String _chatText() {
    final body = ffi.chatModel.messages[MessageKey(ffi.id, ChatModel.clientModeID)];
    if (body == null) return '';
    final me = ffi.chatModel.me.id;
    return body.chatMessages.reversed
        .map((ChatMessage m) =>
            '${m.user.id == me ? 'Técnico' : 'Cliente'}: ${m.text}')
        .join('\n');
  }

  void _deleteAll(List<String> paths) {
    for (final p in paths) {
      if (p.isNotEmpty) File(p).delete().ignore();
    }
  }

  Future<void> _stopAndSummarize({bool peerGone = false}) async {
    busy.value = true;
    _poll?.cancel();
    _poll = null;
    List<String> paths = [];
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('audioStop');
      paths = (res ?? []).map((e) => e.toString()).toList();
    } catch (_) {}
    // Últimos datos (el runner los guarda hasta la siguiente grabación).
    try {
      final st = Map<String, dynamic>.from(await _channel.invokeMethod('audioStatus') as Map);
      final tracks = (st['tracks'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _micMax = math.max(_micMax, (tracks[0]['max'] as num).toDouble());
      _eqMax = math.max(_eqMax, (tracks[1]['max'] as num).toDouble());
      _duration = (st['seconds'] as num).toDouble();
    } catch (_) {}
    recording.value = false;
    micSilent.value = false;
    micLevel.value = eqLevel.value = 0;
    _heartbeat?.cancel();
    _heartbeat = null;
    if (!peerGone) _notifyPeer(false);
    final dur = _duration > 0
        ? _duration
        : (_since == null ? 0.0 : DateTime.now().difference(_since!).inMilliseconds / 1000);
    _since = null;
    var tecnico = paths.isNotEmpty ? paths[0] : '';
    var equipo = paths.length > 1 ? paths[1] : '';
    final micSilentAll = _micMax < _kZero;
    final eqSilentAll = _eqMax < _kZero;
    final chat = _chatText();
    _log('parada: ${dur.toStringAsFixed(1)} s, pico micro ${_micMax.toStringAsFixed(5)}, '
        'pico equipo ${_eqMax.toStringAsFixed(5)}, chat ${chat.length} car.');

    // Nada útil que mandar: se dice y se ofrece descartar (antes se subía y fallaba al final).
    final tooShort = dur < _kMinSeconds;
    final allSilent = micSilentAll && eqSilentAll;
    if (tooShort || allSilent) {
      if (peerGone) {
        _deleteAll([tecnico, equipo]);
        busy.value = false;
        showToast('La grabación para el resumen no tenía audio útil: se ha descartado.',
            timeout: const Duration(seconds: 6));
        return;
      }
      final send = await _askDiscard(dur, tooShort, allSilent, chat.isNotEmpty);
      if (send != true) {
        _deleteAll([tecnico, equipo]);
        busy.value = false;
        _log('descartada por el técnico');
        showToast('Grabación descartada.');
        return;
      }
    }
    // Una pista en silencio no aporta nada a Whisper: no se manda.
    if (micSilentAll && tecnico.isNotEmpty) {
      File(tecnico).delete().ignore();
      tecnico = '';
    }
    if (eqSilentAll && equipo.isNotEmpty) {
      File(equipo).delete().ignore();
      equipo = '';
    }
    if (tecnico.isEmpty && equipo.isEmpty && chat.isEmpty) {
      busy.value = false;
      showToast('No se ha grabado nada de audio.');
      return;
    }
    if (micSilentAll && !eqSilentAll) {
      showToast('Tu micrófono no ha captado nada: el resumen solo lleva lo que se oyó en el equipo.',
          timeout: const Duration(seconds: 6));
    }
    showToast('Preparando el resumen de la asistencia…', timeout: const Duration(seconds: 4));
    try {
      final req = http.MultipartRequest('POST', Uri.parse('${vantarisSummaryUrl()}/resumen'))
        ..fields['equipo_id'] = ffi.id
        ..fields['duracion_min'] = (dur / 60).toStringAsFixed(1)
        ..fields['chat'] = chat;
      if (tecnico.isNotEmpty) {
        req.files.add(await http.MultipartFile.fromPath('tecnico', tecnico));
      }
      if (equipo.isNotEmpty) {
        req.files.add(await http.MultipartFile.fromPath('equipo', equipo));
      }
      final streamed = await req.send().timeout(const Duration(minutes: 15));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode != 200) throw 'el servicio respondió ${resp.statusCode}';
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final resumen = (data['resumen'] ?? '').toString();
      final transcripcion = (data['transcripcion'] ?? '').toString();
      _deleteAll([tecnico, equipo]);
      final saved = await _save(resumen, transcripcion);
      _log('resumen recibido (${resumen.length} car.), guardado en $saved');
      if (peerGone) {
        showToast('Resumen de la asistencia guardado en $saved', timeout: const Duration(seconds: 8));
      } else {
        _showResult(resumen, transcripcion);
      }
    } catch (e) {
      _log('error al enviar: $e');
      final where = [tecnico, equipo].where((p) => p.isNotEmpty).join('\n');
      _showResult('', '', error: 'No se pudo hacer el resumen ($e).\n\n'
          '${where.isEmpty ? '' : 'El audio se ha guardado aquí por si quieres reintentarlo:\n$where'}');
    } finally {
      busy.value = false;
    }
  }

  /// true = enviar igualmente; false/null = descartar.
  Future<bool?> _askDiscard(double dur, bool tooShort, bool allSilent, bool hasChat) {
    final secs = dur.round();
    final why = allSilent
        ? 'No se ha oído nada en ninguna de las dos pistas (ni tu micrófono ni el sonido del '
            'equipo). Suele ser el micrófono apagado o silenciado, o una entrada equivocada en '
            'Windows.'
        : 'La grabación solo ha durado $secs s: es demasiado corta para hacer un resumen.';
    final canSend = !allSilent || hasChat;
    return ffi.dialogManager.show<bool>((setState, close, context) {
      return CustomAlertDialog(
        title: const Text('No se ha enviado al resumen'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(why),
              if (allSilent && tooShort) ...[
                const SizedBox(height: 6),
                Text('Además, solo ha durado $secs s.'),
              ],
              if (allSilent && hasChat) ...[
                const SizedBox(height: 6),
                const Text('Puedes mandar igualmente el chat de la sesión para resumirlo.'),
              ],
            ],
          ),
        ),
        actions: [
          if (canSend)
            dialogButton(allSilent ? 'Resumir solo el chat' : 'Enviar igualmente',
                isOutline: true, onPressed: () => close(true)),
          dialogButton('Descartar', onPressed: () => close(false)),
        ],
        onCancel: () => close(false),
      );
    }).catchError((_) => false);
  }

  /// Guarda resumen y transcripción en Imágenes\Vantaris (junto a las capturas).
  Future<String> _save(String resumen, String transcripcion) async {
    final home = Platform.environment['USERPROFILE'] ?? '.';
    final sep = Platform.pathSeparator;
    final dir = Directory('$home${sep}Pictures${sep}Vantaris');
    await dir.create(recursive: true);
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final file = File('${dir.path}${sep}resumen-${ffi.id}-${n.year}${two(n.month)}'
        '${two(n.day)}-${two(n.hour)}${two(n.minute)}.txt');
    await file.writeAsString(
        ['RESUMEN', '', resumen, '', 'TRANSCRIPCIÓN', '', transcripcion, ''].join('\n'));
    return file.path;
  }

  void _showResult(String resumen, String transcripcion, {String? error}) {
    ffi.dialogManager.show((setState, close, context) {
      final text = error ?? resumen;
      return CustomAlertDialog(
        title: const Text('Resumen de la asistencia'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          if (error == null && transcripcion.isNotEmpty)
            dialogButton('Copiar transcripción', isOutline: true, onPressed: () {
              Clipboard.setData(ClipboardData(text: transcripcion));
              showToast('Transcripción copiada.');
            }),
          if (error == null)
            dialogButton('Copiar resumen', onPressed: () {
              Clipboard.setData(ClipboardData(text: resumen));
              showToast('Resumen copiado: pégalo en el ticket.');
            }),
          dialogButton('Cerrar', isOutline: error == null, onPressed: close),
        ],
        onCancel: close,
      );
    });
  }
}

/// Medidor pequeño junto al botón de grabar: una barra por pista (tú / equipo) y el tiempo.
/// Si el micro no capta nada se pone en naranja. Al pulsarlo, se elige otro micrófono.
class VantarisRecordingMeter extends StatelessWidget {
  final VantarisSummaryState state;
  final double height;
  const VantarisRecordingMeter({Key? key, required this.state, this.height = 24})
      : super(key: key);

  Widget _bar(double level, Color color) => Container(
        width: 5,
        height: height - 6,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: level.clamp(0.0, 1.0),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (state.recording.isFalse) return const SizedBox.shrink();
      final warn = state.micSilent.isTrue || state.micBroken.isTrue;
      final s = state.seconds.value;
      final time = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
      final tip = [
        warn
            ? 'Tu micrófono no capta nada: revisa en Windows cuál es la entrada por defecto.'
            : 'Nivel de la grabación para el resumen.',
        'Tu micro: ${state.micName.value.isEmpty ? '(ninguno)' : state.micName.value}',
        'Sonido del equipo: ${state.eqName.value.isEmpty ? '(ninguno)' : state.eqName.value}',
        'Pulsa para cambiar de micrófono.',
      ].join('\n');
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: () => state.showMicDialog(),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: warn ? Colors.orange.shade800 : const Color(0xFF263238),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(warn ? Icons.mic_off : Icons.mic, size: 14, color: Colors.white),
                const SizedBox(width: 2),
                _bar(state.micLevel.value, warn ? Colors.white : Colors.greenAccent),
                const SizedBox(width: 2),
                _bar(state.eqLevel.value, Colors.lightBlueAccent),
                const SizedBox(width: 5),
                Text(time,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      );
    });
  }
}
