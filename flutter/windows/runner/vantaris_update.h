// Vantaris: actualizaciones automáticas de «Vantaris Soporte» (Windows). Ver vantaris_update.cpp.
#pragma once
#include <string>
#include <vector>

// Si args[0] es «--vantaris-actualizar», hace la comprobación/actualización y devuelve el código de
// salida del proceso. Si no, devuelve -1 y no hace nada.
int VantarisUpdateMain(const std::vector<std::string>& args);

// En el proceso del servicio («--service») de Vantaris Soporte arranca el hilo que cada 6 h lanza
// «<exe> --vantaris-actualizar». En cualquier otro caso no hace nada.
void VantarisUpdateStartScheduler(const std::vector<std::string>& args);
