// Vantaris: permiso «Mostrar sobre otras apps» en Android (pizarra, láser, foco, aviso y «no tocar»).
//
// Todo lo que el técnico pone encima de la pantalla del equipo es una capa del sistema
// (VantarisDrawOverlay.kt / VantarisGuard.kt) y sin ese permiso Android no la deja poner: no se ve
// nada y nadie se entera. Lo da provisionar-android.ps1 por adb o el alta del equipo; si se instaló
// de otra forma falta. Ahora:
//   - Equipo: si llega dibujo y falta el permiso, contesta «w 0» al técnico (como mucho cada 20 s por
//     conexión) y la pantalla principal enseña una tarjeta con «Permitir».
//   - Técnico: aviso de qué pasa y cómo arreglarlo (lo puede hacer él mismo desde el control remoto).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';
import 'draw.dart';

/// Equipo Android: ha llegado dibujo sin permiso (enseña la tarjeta aunque no se haya mirado aún).
final vantarisFaltaPermisoCapa = false.obs;

final _ultimoAviso = <int, DateTime>{};

/// Equipo: la capa no se ha podido poner en la conexión [connId].
void vantarisSinPermisoCapa(int connId) {
  vantarisFaltaPermisoCapa.value = true;
  final ahora = DateTime.now();
  final antes = _ultimoAviso[connId];
  if (antes != null && ahora.difference(antes) < const Duration(seconds: 20)) return;
  _ultimoAviso[connId] = ahora;
  bind.cmSendChat(connId: connId, msg: '${kVantarisDrawPrefix}w 0');
}

/// Técnico: «w 0» del equipo.
void vantarisPermisoCapaFromPeer(String body) {
  showToast(
      'El equipo no deja pintar encima: falta el permiso «Mostrar sobre otras apps». '
      'Abre la app Vantaris Soporte en el equipo y pulsa «Permitir» en el aviso de arriba '
      '(lo puedes hacer tú desde aquí).',
      timeout: const Duration(seconds: 10));
}

/// Tarjeta de la pantalla principal (Android) mientras falte el permiso.
class VantarisPermisoCapaCard extends StatefulWidget {
  const VantarisPermisoCapaCard({Key? key}) : super(key: key);

  @override
  State<VantarisPermisoCapaCard> createState() => _VantarisPermisoCapaCardState();
}

class _VantarisPermisoCapaCardState extends State<VantarisPermisoCapaCard> {
  bool? _concedido;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _mirar();
    // Al volver de los ajustes de Android no hay aviso: se mira cada pocos segundos.
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _mirar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _mirar() async {
    final ok = await AndroidPermissionManager.check(kSystemAlertWindow);
    if (ok) vantarisFaltaPermisoCapa.value = false;
    if (mounted && ok != _concedido) setState(() => _concedido = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (!isAndroid || _concedido != false) return const SizedBox.shrink();
    return Obx(() {
      final urgente = vantarisFaltaPermisoCapa.value;
      return Card(
        color: urgente ? const Color(0xFFFFF4E5) : null,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.draw_outlined, color: urgente ? const Color(0xFFF59E0B) : const Color(0xFF0D9488)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    urgente
                        ? 'El técnico está intentando señalarte algo en la pantalla'
                        : 'Deja que el técnico te señale en la pantalla',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 6),
            const Text('Para ver lo que dibuja el técnico y el aviso de «técnico conectado», Android '
                'necesita el permiso «Mostrar sobre otras apps».'),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0D9488)),
                onPressed: () async {
                  await AndroidPermissionManager.request(kSystemAlertWindow);
                  _mirar();
                },
                child: const Text('Permitir'),
              ),
            ),
          ]),
        ),
      );
    });
  }
}
