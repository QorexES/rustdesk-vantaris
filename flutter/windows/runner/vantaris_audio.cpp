#include "vantaris_audio.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
// Despues de mmdeviceapi.h (necesita sus definiciones de PROPERTYKEY).
#include <functiondiscoverykeys_devpkey.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>

#pragma comment(lib, "ole32.lib")

namespace vantaris_audio {
namespace {

constexpr uint32_t kRate = 16000;  // Whisper trabaja a 16 kHz
constexpr uint64_t kMaxGap = kRate / 10;  // mas de 100 ms de hueco: se rellena con silencio
constexpr DWORD kRetryMs = 2000;  // sin dispositivo: se reintenta abrir cada 2 s

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return "";
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0,
                                    nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr,
                      nullptr);
  return s;
}

class WavWriter {
 public:
  bool Open(const std::wstring& path) {
    path_ = path;
    samples_ = 0;
    if (_wfopen_s(&f_, path.c_str(), L"wb") != 0 || !f_) {
      f_ = nullptr;
      return false;
    }
    WriteHeader(0);
    return true;
  }
  void Write(const int16_t* s, size_t n) {
    if (!f_ || !n) return;
    fwrite(s, sizeof(int16_t), n, f_);
    samples_ += n;
  }
  void Silence(uint64_t n) {
    static const int16_t zeros[1600] = {};
    while (n) {
      const size_t k = static_cast<size_t>(n < 1600 ? n : 1600);
      Write(zeros, k);
      n -= k;
    }
  }
  void Close() {
    if (!f_) return;
    fseek(f_, 0, SEEK_SET);
    WriteHeader(samples_);
    fclose(f_);
    f_ = nullptr;
  }
  bool is_open() const { return f_ != nullptr; }
  uint64_t samples() const { return samples_; }
  const std::wstring& path() const { return path_; }

 private:
  void U32(uint32_t v) { fwrite(&v, 4, 1, f_); }
  void U16(uint16_t v) { fwrite(&v, 2, 1, f_); }
  void WriteHeader(uint64_t n) {
    const uint32_t data = static_cast<uint32_t>(n * 2);
    fwrite("RIFF", 1, 4, f_);
    U32(36 + data);
    fwrite("WAVEfmt ", 1, 8, f_);
    U32(16);
    U16(1);  // PCM
    U16(1);  // mono
    U32(kRate);
    U32(kRate * 2);
    U16(2);
    U16(16);
    fwrite("data", 1, 4, f_);
    U32(data);
  }
  FILE* f_ = nullptr;
  std::wstring path_;
  uint64_t samples_ = 0;
};

// Lo que Dart consulta mientras se graba (medidor de nivel y aviso de micro en silencio).
struct TrackState {
  std::atomic<int> state{0};
  std::atomic<float> peak{0};
  std::atomic<float> max_peak{0};
  std::mutex name_mutex;
  std::string name;

  void Reset(bool keep_max) {
    state = 0;
    peak = 0;
    if (!keep_max) max_peak = 0;
    SetName("");
  }
  void SetName(const std::string& n) {
    std::lock_guard<std::mutex> lock(name_mutex);
    name = n;
  }
  std::string Name() {
    std::lock_guard<std::mutex> lock(name_mutex);
    return name;
  }
};

std::mutex g_mutex;
bool g_running = false;
std::atomic<bool> g_stop[2];
WavWriter g_writers[2];  // 0 = tecnico (microfono), 1 = equipo (loopback)
TrackState g_state[2];
std::thread g_threads[2];
std::wstring g_mic_id;  // vacio = entrada predeterminada
std::atomic<ULONGLONG> g_start{0};
std::atomic<ULONGLONG> g_end{0};

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

void AtomicMax(std::atomic<float>& a, float v) {
  float cur = a.load();
  while (v > cur && !a.compare_exchange_weak(cur, v)) {
  }
}

std::string FriendlyName(IMMDevice* device) {
  std::string out;
  IPropertyStore* props = nullptr;
  if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
    PROPVARIANT v;
    PropVariantInit(&v);
    if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &v)) && v.vt == VT_LPWSTR) {
      out = WideToUtf8(v.pwszVal);
    }
    PropVariantClear(&v);
    props->Release();
  }
  return out;
}

// Rellena con silencio hasta el tiempo real: las dos pistas van siempre alineadas.
bool Pad(WavWriter* out) {
  const uint64_t expected = (GetTickCount64() - g_start) * kRate / 1000;
  if (out->samples() + kMaxGap < expected) {
    out->Silence(expected - out->samples());
    return true;
  }
  return false;
}

// Abre el dispositivo y captura hasta parar o perderlo. false si no se pudo abrir.
bool CaptureOnce(int track, const std::wstring& device_id, std::atomic<bool>* stop) {
  const bool loopback = track == 1;
  WavWriter* out = &g_writers[track];
  TrackState& st = g_state[track];
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* wf = nullptr;
  bool opened = false;
  do {
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator)))) {
      break;
    }
    // Un micro elegido que ya no esta (casco apagado, USB fuera): se usa el predeterminado.
    if (!device_id.empty() && FAILED(enumerator->GetDevice(device_id.c_str(), &device))) {
      device = nullptr;
    }
    // eConsole = la «entrada/salida predeterminada» de Configuracion de Windows (la que usa
    // tambien la llamada de voz de RustDesk).
    if (!device && FAILED(enumerator->GetDefaultAudioEndpoint(loopback ? eRender : eCapture,
                                                              eConsole, &device))) {
      break;
    }
    st.SetName(FriendlyName(device));
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&client)))) {
      break;
    }
    if (FAILED(client->GetMixFormat(&wf))) break;
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0, 10000000, 0, wf,
                                  nullptr))) {
      break;
    }
    if (FAILED(client->GetService(__uuidof(IAudioCaptureClient),
                                  reinterpret_cast<void**>(&capture)))) {
      break;
    }
    bool is_float = wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      // El subtipo lleva el formato en Data1 (KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = 3).
      is_float = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(wf)->SubFormat.Data1 ==
                 WAVE_FORMAT_IEEE_FLOAT;
    }
    const int channels = wf->nChannels;
    const int bits = wf->wBitsPerSample;
    const uint64_t in_rate = wf->nSamplesPerSec;
    if (FAILED(client->Start())) break;
    opened = true;
    st.state = 1;

    uint64_t in_total = 0, out_total = 0;
    double sum = 0;
    int count = 0;
    std::vector<int16_t> buf;
    bool lost = false;
    while (!*stop && !lost) {
      Sleep(10);
      UINT32 packet = 0;
      HRESULT hr;
      while (SUCCEEDED(hr = capture->GetNextPacketSize(&packet)) && packet) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) break;
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        float peak = 0;
        buf.clear();
        for (UINT32 i = 0; i < frames; ++i) {
          double mono = 0;
          if (!silent) {
            for (int c = 0; c < channels; ++c) {
              const size_t idx = static_cast<size_t>(i) * channels + c;
              double v = 0;
              if (is_float) {
                v = reinterpret_cast<const float*>(data)[idx];
              } else if (bits == 16) {
                v = reinterpret_cast<const int16_t*>(data)[idx] / 32768.0;
              } else if (bits == 32) {
                v = reinterpret_cast<const int32_t*>(data)[idx] / 2147483648.0;
              }
              const float a = static_cast<float>(std::fabs(v));
              if (a > peak) peak = a;
              mono += v;
            }
            mono /= channels;
          }
          // Diezmado por media hasta 16 kHz.
          sum += mono;
          ++count;
          ++in_total;
          if (in_total * kRate >= (out_total + 1) * in_rate) {
            double v = sum / count;
            v = v > 1 ? 1 : (v < -1 ? -1 : v);
            buf.push_back(static_cast<int16_t>(v * 32767));
            sum = 0;
            count = 0;
            ++out_total;
          }
        }
        capture->ReleaseBuffer(frames);
        out->Write(buf.data(), buf.size());
        AtomicMax(st.peak, peak);
        AtomicMax(st.max_peak, peak);
      }
      if (hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING) {
        lost = true;  // casco apagado, USB desenchufado...: se vuelve a abrir
        st.state = -2;
      }
      // El loopback no manda nada mientras no suena nada: rellenar para no desalinear las pistas.
      if (Pad(out)) {
        out_total = 0;
        in_total = 0;
      }
    }
    client->Stop();
  } while (false);
  if (wf) CoTaskMemFree(wf);
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  return opened;
}

// Hilo de una pista: captura y, si no hay dispositivo o se pierde, rellena y reintenta.
void Capture(int track, std::wstring device_id) {
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
  std::atomic<bool>* stop = &g_stop[track];
  while (!*stop) {
    if (!CaptureOnce(track, device_id, stop) && g_state[track].state != -2) {
      g_state[track].state = -1;
    }
    const ULONGLONG t0 = GetTickCount64();
    while (!*stop && GetTickCount64() - t0 < kRetryMs) {
      Sleep(20);
      Pad(&g_writers[track]);
    }
  }
  Pad(&g_writers[track]);
  CoUninitialize();
}

void StartTrack(int track, bool keep_max = false) {
  g_state[track].Reset(keep_max);
  g_stop[track] = false;
  g_threads[track] = std::thread(Capture, track, track == 0 ? g_mic_id : std::wstring());
}

void StopTrack(int track) {
  g_stop[track] = true;
  if (g_threads[track].joinable()) g_threads[track].join();
}

}  // namespace

bool Start(const std::string& dir, const std::string& mic_id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_running) return false;
  const std::wstring base = Utf8ToWide(dir) + L"\\vantaris-audio-" +
                            std::to_wstring(GetTickCount64());
  const bool mic = g_writers[0].Open(base + L"-tecnico.wav");
  const bool loop = g_writers[1].Open(base + L"-equipo.wav");
  if (!mic || !loop) {
    for (auto& w : g_writers) {
      if (w.is_open()) {
        w.Close();
        DeleteFileW(w.path().c_str());
      }
    }
    return false;
  }
  g_mic_id = Utf8ToWide(mic_id);
  g_start = GetTickCount64();
  g_end = 0;
  StartTrack(0);
  StartTrack(1);
  g_running = true;
  return true;
}

void SetMic(const std::string& mic_id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_mic_id = Utf8ToWide(mic_id);
  if (!g_running) return;
  StopTrack(0);
  StartTrack(0, true);  // sigue escribiendo en el mismo WAV; el hueco se rellena con silencio
}

std::vector<std::string> Stop() {
  std::lock_guard<std::mutex> lock(g_mutex);
  std::vector<std::string> paths(2);
  if (!g_running) return {};
  for (int i = 0; i < 2; ++i) StopTrack(i);
  g_end = GetTickCount64();
  for (int i = 0; i < 2; ++i) {
    const bool has_audio = g_writers[i].samples() > kRate;  // al menos 1 s
    g_writers[i].Close();
    if (has_audio) {
      paths[i] = WideToUtf8(g_writers[i].path());
    } else {
      DeleteFileW(g_writers[i].path().c_str());
    }
  }
  g_running = false;
  return paths;
}

Status GetStatus() {
  Status s;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    s.running = g_running;
  }
  const ULONGLONG start = g_start;
  const ULONGLONG end = g_end ? g_end.load() : GetTickCount64();
  s.seconds = start ? (end - start) / 1000.0 : 0;
  for (int i = 0; i < 2; ++i) {
    s.tracks[i].state = g_state[i].state;
    s.tracks[i].name = g_state[i].Name();
    s.tracks[i].peak = g_state[i].peak.exchange(0);
    s.tracks[i].max_peak = g_state[i].max_peak;
  }
  return s;
}

std::vector<std::pair<std::string, std::string>> ListInputs(std::string* default_id) {
  std::vector<std::pair<std::string, std::string>> list;
  const HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDeviceCollection* devices = nullptr;
  IMMDevice* device = nullptr;
  if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                 __uuidof(IMMDeviceEnumerator),
                                 reinterpret_cast<void**>(&enumerator)))) {
    if (default_id &&
        SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device))) {
      LPWSTR id = nullptr;
      if (SUCCEEDED(device->GetId(&id))) {
        *default_id = WideToUtf8(id);
        CoTaskMemFree(id);
      }
      SafeRelease(&device);
    }
    if (SUCCEEDED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &devices))) {
      UINT n = 0;
      devices->GetCount(&n);
      for (UINT i = 0; i < n; ++i) {
        if (FAILED(devices->Item(i, &device))) continue;
        LPWSTR id = nullptr;
        if (SUCCEEDED(device->GetId(&id))) {
          list.emplace_back(WideToUtf8(id), FriendlyName(device));
          CoTaskMemFree(id);
        }
        SafeRelease(&device);
      }
      SafeRelease(&devices);
    }
    SafeRelease(&enumerator);
  }
  if (SUCCEEDED(co)) CoUninitialize();
  return list;
}

}  // namespace vantaris_audio
