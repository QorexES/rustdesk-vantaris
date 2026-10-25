// Vantaris: marca «pulpo con auriculares + herramientas» (logotipo de Soporte y de Técnico).
//
// Tres colores, según el cliente:
//   - negativo (por defecto): pulpo blanco y aguamarina claro sobre azul marino.
//   - positivo: pulpo azul marino y teal sobre blanco.
//   - mono-blanco: todo blanco sobre aguamarina.
// Cada uno va siempre sobre su fondo (tarjeta redondeada), así se lee igual en tema claro y oscuro.
//
// Cómo se elige: Ajustes › General › «Logo de Vantaris» (opción `vantaris-logo`), o el técnico desde
// su barra durante la asistencia (orden «K <color>» por el canal de la pizarra; el equipo contesta
// «k <color>»). La config firmada de Pro puede traerlo en default-settings (valor inicial) u
// override-settings (fijo: sin selector y sin cambio remoto). Al compilar se puede cambiar el de por
// defecto con --dart-define=VANTARIS_LOGO=positivo.
//
// Los SVG (textos ya convertidos a trazos) los genera RemoteControl/client-build/marca/generar-marca.py.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../models/model.dart';
import '../models/platform_model.dart';
import 'draw.dart';
import 'tecnico.dart';

const kVantarisLogoOption = 'vantaris-logo';
const _kPorDefecto = String.fromEnvironment('VANTARIS_LOGO', defaultValue: 'negativo');

/// Colores disponibles y su nombre en el selector.
const vantarisLogoColores = {
  'negativo': 'Negativo',
  'positivo': 'Positivo',
  'mono-blanco': 'Mono blanco',
};

const _kFondos = {
  'negativo': Color(0xFF1A2B4F),
  'positivo': Color(0xFFFFFFFF),
  'mono-blanco': Color(0xFF0D9488),
};

String _valido(String v) => vantarisLogoColores.containsKey(v) ? v : '';

String _leer() {
  final guardado = _valido(bind.mainGetOptionSync(key: kVantarisLogoOption));
  if (guardado.isNotEmpty) return guardado;
  final compilado = _valido(_kPorDefecto);
  return compilado.isNotEmpty ? compilado : 'negativo';
}

/// Color en uso. Se lee la primera vez que se pinta la marca (ya con la librería cargada).
final vantarisLogo = _leer().obs;

Future<void> vantarisCambiarLogo(String color) async {
  if (_valido(color).isEmpty) return;
  vantarisLogo.value = color;
  await bind.mainSetOption(key: kVantarisLogoOption, value: color);
}

/// Equipo controlado: «K <color>» del técnico. Contesta «k <color>» con el que queda puesto.
void vantarisLogoFromController(int connId, String body) {
  final color = body.trim().split(' ').last;
  if (_valido(color).isNotEmpty && !isOptionFixed(kVantarisLogoOption)) {
    vantarisCambiarLogo(color);
  }
  bind.cmSendChat(connId: connId, msg: '${kVantarisDrawPrefix}k ${vantarisLogo.value}');
}

/// Técnico: respuesta «k <color>» del equipo.
void vantarisLogoFromPeer(String body) {
  final color = body.trim().split(' ').last;
  showToast('Logo del equipo: ${vantarisLogoColores[color] ?? color}');
}

/// Técnico: cambia el color del logo en el equipo de la sesión.
Future<void> vantarisEnviarLogo(FFI ffi, String color) async {
  if (!await vantarisPeerSupportsDraw(ffi.sessionId) || !vantarisPeerHas(ffi.sessionId, 'logo')) {
    showToast('El equipo no tiene una versión de Vantaris Soporte que deje cambiar el logo.');
    return;
  }
  bind.sessionSendChat(sessionId: ffi.sessionId, text: '${kVantarisDrawPrefix}K $color');
}

String get _variante => vantarisEsTecnico ? 'tecnico' : 'soporte';

/// Icono de la app (pestañas, ventana de conexiones). Soporte en azul marino, Técnico en teal.
String get vantarisIconoAsset => 'assets/vantaris/icono-$_variante.svg';

Widget _tarjeta(String color, double alto, {EdgeInsets? relleno}) {
  return Container(
    padding: relleno ?? EdgeInsets.symmetric(horizontal: alto * 0.3, vertical: alto * 0.22),
    decoration: BoxDecoration(
      color: _kFondos[color],
      borderRadius: BorderRadius.circular(12),
      // El positivo es blanco: con borde para que no se pierda sobre el fondo claro de la app.
      border: color == 'positivo' ? Border.all(color: const Color(0xFFE2E8F0)) : null,
    ),
    child: SvgPicture.asset('assets/vantaris/logotipo-$_variante-$color.svg', height: alto),
  );
}

/// Logotipo en la pantalla principal y en Ajustes.
class VantarisMarca extends StatelessWidget {
  final double alto;
  const VantarisMarca({Key? key, this.alto = 40}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: FittedBox(fit: BoxFit.scaleDown, child: _tarjeta(vantarisLogo.value, alto)),
        ));
  }
}

/// Selector del color del logo (Ajustes de escritorio y de Android).
class VantarisLogoSelector extends StatelessWidget {
  const VantarisLogoSelector({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final fijo = isOptionFixed(kVantarisLogoOption);
    return Obx(() {
      final actual = vantarisLogo.value;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: vantarisLogoColores.entries.map((e) {
          final elegido = e.key == actual;
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: fijo || elegido ? null : () => vantarisCambiarLogo(e.key),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: elegido ? const Color(0xFF0D9488) : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Opacity(opacity: fijo && !elegido ? 0.4 : 1, child: _tarjeta(e.key, 26)),
                const SizedBox(height: 4),
                Text(
                  elegido ? '✓ ${e.value}' : e.value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: elegido ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ]),
            ),
          );
        }).toList(),
      ).marginOnly(left: 12, top: 4, bottom: 8);
    });
  }
}
