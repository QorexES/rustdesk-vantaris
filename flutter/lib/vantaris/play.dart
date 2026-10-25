// Vantaris: versión para Google Play (compilada con VANTARIS_PLAY=1, ver build-vantaris.sh).
//
// Diferencias con el APK de descarga directa:
//   - Sin actualizador propio: las actualizaciones las da Play (updater.dart no consulta nada).
//   - Aviso destacado ANTES de mandar al usuario a Ajustes › Accesibilidad (política de la API de
//     accesibilidad de Google Play): qué hace el servicio, qué datos usa y que se puede quitar. Sin
//     «Aceptar» no se abre el ajuste.
//   - Aviso breve antes de pedir la captura de pantalla.
// Sin la variable todo sigue como en el APK de siempre.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../common.dart';

/// true en la compilación para Google Play.
const kVantarisPlay = bool.fromEnvironment('VANTARIS_PLAY');

/// Nombre visible (el app-name de la config Pro no admite espacios: «VantarisSoporte»).
const kVantarisNombre = 'Vantaris Soporte';

/// Política de privacidad (Ajustes › Declaración de privacidad).
const kVantarisPrivacidadUrl = 'https://vantaris.es/legal/privacidad-soporte-remoto';

/// Código fuente del fork (AGPL-3.0). La config de Soporte oculta «Acerca de» (disable-settings).
const kVantarisCodigoFuenteUrl = 'https://github.com/QorexES/rustdesk-vantaris';

/// Enlace discreto al pie de la pantalla principal.
class VantarisCodigoFuente extends StatelessWidget {
  const VantarisCodigoFuente({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton(
      onPressed: () => launchUrlString(kVantarisCodigoFuenteUrl,
          mode: LaunchMode.externalApplication),
      child: Text('Código fuente (AGPL)',
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
              decoration: TextDecoration.underline)),
      ),
    );
  }
}

const kVantarisAvisoAccesibilidadTitulo = 'Control del dispositivo por el técnico';
const kVantarisAvisoAccesibilidad = [
  'Vantaris Soporte usa el servicio de accesibilidad de Android para que el técnico de Vantaris, '
      'con tu permiso, pueda mover el puntero, pulsar y escribir en este dispositivo durante una '
      'sesión de soporte.',
  'Solo funciona mientras hay una sesión de soporte que tú has aceptado. No se recogen ni se '
      'guardan los datos de la pantalla fuera de la sesión.',
  'Puedes desactivarlo cuando quieras en Ajustes › Accesibilidad › «Vantaris Soporte (control '
      'remoto)».',
  'Si aceptas, se abrirán los ajustes de accesibilidad: entra en «Vantaris Soporte (control '
      'remoto)» y actívalo.',
];

const kVantarisAvisoCapturaTitulo = 'Compartir la pantalla';
const kVantarisAvisoCaptura = [
  'Para que el técnico de Vantaris vea tu pantalla durante la asistencia, Android te pedirá permiso '
      'para capturarla.',
  'La imagen solo se envía al técnico mientras dura la sesión que tú aceptas. Puedes pararlo cuando '
      'quieras con «Detener servicio».',
];

Future<bool> _aviso(OverlayDialogManager dm, String titulo, List<String> textos) async {
  final res = await dm.show<bool>((setState, close, context) {
    submit() => close(true);
    cancel() => close(false);
    return CustomAlertDialog(
      title: Text(titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < textos.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Text(textos[i]),
          ],
        ],
      ),
      actions: [
        dialogButton('No, gracias', onPressed: cancel, isOutline: true),
        dialogButton('Aceptar', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
  return res == true;
}

/// Aviso destacado de accesibilidad. Devuelve true solo si el usuario pulsa «Aceptar».
Future<bool> vantarisAvisoAccesibilidad(OverlayDialogManager dm) =>
    _aviso(dm, kVantarisAvisoAccesibilidadTitulo, kVantarisAvisoAccesibilidad);

/// Aviso breve antes de pedir la captura de pantalla. true = «Aceptar».
Future<bool> vantarisAvisoCaptura(OverlayDialogManager dm) =>
    _aviso(dm, kVantarisAvisoCapturaTitulo, kVantarisAvisoCaptura);
