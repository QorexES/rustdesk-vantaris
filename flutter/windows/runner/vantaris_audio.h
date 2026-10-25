#ifndef RUNNER_VANTARIS_AUDIO_H_
#define RUNNER_VANTARIS_AUDIO_H_

#include <string>
#include <utility>
#include <vector>

// Vantaris: grabacion de la asistencia para el resumen automatico (flutter/lib/vantaris/summary.dart).
// Dos pistas separadas, para saber quien habla: el microfono del tecnico y lo que suena en su
// equipo (loopback), que es donde llega la voz del cliente por la llamada de RustDesk.
// WAV PCM 16 bits, mono, 16 kHz (lo que usa Whisper). Los huecos (loopback sin sonido, microfono
// que falla o que se cambia a media grabacion) se rellenan para que las dos pistas vayan alineadas.
namespace vantaris_audio {

// Empieza a grabar en [dir] (UTF-8). [mic_id]: id WASAPI del microfono, vacio = la entrada
// predeterminada de Windows. Devuelve false si ya se estaba grabando o no se pueden crear los WAV.
bool Start(const std::string& dir, const std::string& mic_id);

// Para y devuelve las rutas UTF-8 de los WAV escritos (tecnico, equipo); vacio si no habia nada.
std::vector<std::string> Stop();

// Cambia el microfono (vacio = predeterminado). Si se esta grabando, sigue en el mismo WAV.
void SetMic(const std::string& mic_id);

struct Track {
  int state = 0;         // 0 arrancando, 1 capturando, -1 no se pudo abrir, -2 dispositivo perdido
  std::string name;      // nombre del dispositivo en Windows
  double peak = 0;       // pico desde la ultima consulta (0..1)
  double max_peak = 0;   // pico desde que empezo la grabacion
};

struct Status {
  bool running = false;
  double seconds = 0;
  Track tracks[2];  // 0 = tecnico (microfono), 1 = equipo (loopback)
};

// Estado de la grabacion (sigue valido tras Stop hasta el siguiente Start). Pone a cero [peak].
Status GetStatus();

// Microfonos activos: (id, nombre). [default_id] recibe el de la entrada predeterminada.
std::vector<std::pair<std::string, std::string>> ListInputs(std::string* default_id);

}  // namespace vantaris_audio

#endif  // RUNNER_VANTARIS_AUDIO_H_
