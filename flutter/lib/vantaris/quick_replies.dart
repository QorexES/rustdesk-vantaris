// Vantaris: respuestas rápidas del técnico para el chat de la sesión.
//
// Frases hechas en lenguaje llano para el hostelero («Estoy revisando la impresora, no toque
// nada, por favor»…). Salen en un menú de la barra del técnico y en un botón de la ventana de
// chat; al elegir una se manda por el chat NORMAL de la sesión (no por el canal VTD1 de la
// pizarra), así llega también a un RustDesk sin Vantaris. En Android Vantaris el cliente la ve
// en una tarjeta encima de todo (VantarisGuard.kt).
//
// El técnico las edita (añadir, cambiar, quitar, restaurar) y se guardan en la opción local
// «vantaris-respuestas-rapidas» (JSON con la lista).

import 'dart:convert';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';

import '../common.dart';
import '../models/chat_model.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

const _kOption = 'vantaris-respuestas-rapidas';
const _kMax = 20;
const _kMaxLength = 300;

const kVantarisDefaultQuickReplies = [
  'Hola, soy el técnico de Vantaris. Ya estoy conectado a su equipo.',
  'Estoy revisando la impresora, no toque nada, por favor.',
  'Un momento, voy a reiniciar la aplicación.',
  '¿Puede decirme qué error le sale?',
  'Voy a tomar el control un momento. Por favor, no toque la pantalla.',
  'Ya puede usar el equipo.',
  '¿Puede probar ahora y decirme si funciona?',
  'Listo, ya está solucionado. ¡Gracias!',
];

List<String> vantarisQuickReplies() {
  try {
    final raw = bind.mainGetLocalOption(key: _kOption);
    if (raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return list; // una lista vacía guardada a propósito también vale
    }
  } catch (_) {}
  return List.of(kVantarisDefaultQuickReplies);
}

Future<void> _save(List<String> list) => bind.mainSetLocalOption(
    key: _kOption, value: list.isEmpty ? '[]' : jsonEncode(list));

/// Manda [text] al cliente por el chat de la sesión (queda en el historial del chat).
void vantarisSendQuickReply(ChatModel chat, String text, {String? peerId}) {
  final t = text.trim();
  if (t.isEmpty) return;
  final id = peerId ?? chat.parent.target?.id;
  if (id != null && chat.currentKey.connId != ChatModel.clientModeID) {
    chat.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
  }
  chat.send(ChatMessage(text: t, user: chat.me, createdAt: DateTime.now()));
}

/// Botón de la ventana de chat del técnico (junto al cuadro de texto). Null si no toca.
List<Widget>? vantarisChatLeading(ChatModel chat) {
  if (!isDesktop || chat.isConnManager) return null;
  if (chat.currentKey.connId != ChatModel.clientModeID) return null;
  return [
    PopupMenuButton<String>(
      tooltip: 'Respuestas rápidas',
      icon: const Icon(Icons.quickreply_outlined, size: 20),
      padding: EdgeInsets.zero,
      itemBuilder: (context) => [
        ...vantarisQuickReplies().map((t) => PopupMenuItem<String>(
              value: t,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(t, style: const TextStyle(fontSize: 13))),
            )),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '',
          child: Text('Editar frases…', style: TextStyle(fontSize: 13)),
        ),
      ],
      onSelected: (t) {
        final ffi = chat.parent.target;
        if (t.isEmpty) {
          if (ffi != null) vantarisEditQuickReplies(ffi);
        } else {
          vantarisSendQuickReply(chat, t);
        }
      },
    ),
  ];
}

/// Editor de las frases: cambiar, quitar, añadir y volver a las de fábrica.
void vantarisEditQuickReplies(FFI ffi) {
  final controllers =
      vantarisQuickReplies().map((t) => TextEditingController(text: t)).toList();
  ffi.dialogManager.show((setState, close, context) {
    void add() {
      if (controllers.length >= _kMax) return;
      setState(() => controllers.add(TextEditingController()));
    }

    return CustomAlertDialog(
      title: const Text('Respuestas rápidas'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Frases que mandas al cliente con un clic desde la barra o el chat. '
                'Escríbelas como se las dirías al hostelero.',
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < controllers.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(children: [
                          Expanded(
                            child: TextField(
                              controller: controllers[i],
                              maxLength: _kMaxLength,
                              maxLines: null,
                              decoration: const InputDecoration(
                                  isDense: true, counterText: '', border: OutlineInputBorder()),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Quitar',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => setState(() => controllers.removeAt(i)),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
            if (controllers.length < _kMax)
              TextButton.icon(
                  onPressed: add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Añadir frase')),
          ],
        ),
      ),
      actions: [
        dialogButton('Restaurar las de fábrica', isOutline: true, onPressed: () {
          setState(() {
            controllers
              ..clear()
              ..addAll(kVantarisDefaultQuickReplies.map((t) => TextEditingController(text: t)));
          });
        }),
        dialogButton('Cancelar', isOutline: true, onPressed: close),
        dialogButton('Guardar', onPressed: () async {
          final list = controllers
              .map((c) => c.text.trim())
              .where((t) => t.isNotEmpty)
              .toSet() // sin repetidas
              .toList();
          await _save(list);
          close();
          showToast('Respuestas rápidas guardadas.');
        }),
      ],
      onCancel: close,
    );
  });
}
