#ifndef RUNNER_VANTARIS_DIAG_H_
#define RUNNER_VANTARIS_DIAG_H_

#include <string>

// Vantaris: datos del sistema para el diagnóstico remoto (flutter/lib/vantaris/diag.dart).
// Solo lectura: bateria, disco del sistema, memoria, version de Windows y red activa.
namespace vantaris_diag {

// JSON UTF-8 con: so, bateria/cargando/enchufado o sinBateria, discoLibreMb, discoTotalMb,
// memLibreMb, memTotalMb, red {tipo, ip}.
std::string SysInfoJson();

}  // namespace vantaris_diag

#endif  // RUNNER_VANTARIS_DIAG_H_
