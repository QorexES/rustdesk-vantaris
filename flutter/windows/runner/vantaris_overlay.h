#ifndef RUNNER_VANTARIS_OVERLAY_H_
#define RUNNER_VANTARIS_OVERLAY_H_

#include <string>

// Vantaris: capa transparente encima de todo donde se pintan el lapiz y el laser del tecnico
// en el equipo Windows controlado. No recibe raton ni teclado y se excluye de la captura de
// pantalla (el tecnico ya ve sus trazos en local; asi no salen repetidos).
// Las ordenes llegan desde Dart (flutter/lib/vantaris/draw.dart) por el canal
// org.rustdesk.rustdesk/host, metodo "vantarisOverlay". Protocolo: ver draw.dart.
namespace vantaris_overlay {

// Procesa un bloque de ordenes (una por linea). Hay que llamarlo desde el hilo de la interfaz.
void Handle(const std::string& payload);

// Copia al portapapeles (CF_DIB) la imagen del fichero indicado (ruta UTF-8). Para pegar en
// el ticket las capturas del tecnico (flutter/lib/vantaris/capture.dart).
bool CopyImageFile(const std::string& utf8_path);

}  // namespace vantaris_overlay

#endif  // RUNNER_VANTARIS_OVERLAY_H_
