// Vantaris: actualizaciones automáticas de «Vantaris Soporte» en Windows, sin preguntar.
//
// Por qué en el runner (C++) y no en Dart: en un TPV la ventana de RustDesk casi nunca está abierta
// y, aunque lo esté, corre como el usuario del local (sin permisos para tocar Archivos de programa).
// El único proceso que está siempre y como SYSTEM es el servicio («<exe> --service»), y ese pasa por
// este runner antes de entrar en librustdesk. Así que:
//   - En «--service» se arranca un hilo que cada 6 h lanza «<exe> --vantaris-actualizar».
//   - «--vantaris-actualizar» (este fichero, sin Rust ni Flutter):
//       1. Lee vantaris-version.txt (junto al .exe; lo escribe build-vantaris.sh): variante, build,
//          canal, claves públicas y, opcional, la URL base.
//       2. Baja <base>/<canal>/windows-<variante>.json, verifica la firma Ed25519 con esas claves y
//          que variante/plataforma/canal coinciden y que el build es MAYOR que el instalado.
//       3. Si hay asistencia en curso (latido del proceso --cm en %ProgramData%\Vantaris\sesion-activa,
//          o conexión por el relay 21117), lo deja para la próxima vuelta.
//       4. Baja el ZIP a <carpeta del programa>\vantaris-actualizacion\ (solo administradores pueden
//          escribir ahí: nadie puede cambiar el paquete entre la comprobación y la instalación),
//          comprueba tamaño y SHA-256, lo descomprime (tar.exe de Windows) y, si sigue sin haber
//          asistencia, lanza «<nuevo>.exe --update», que es el mismo camino que usa RustDesk: para el
//          servicio, copia la carpeta encima de la instalada y lo vuelve a arrancar.
//   Opciones: --comprobar (solo mira el manifiesto), --sin-instalar (todo menos lanzar --update).
//   Códigos de salida: 0 al día · 10 hay versión (--comprobar) · 3 pospuesta por asistencia ·
//   2 RECHAZADA (firma, hash, variante…) · 20 actualización lanzada · 1 error.
//   Registro: <carpeta del programa>\vantaris-actualizaciones.log
//   Ajustes (solo administradores), HKLM\SOFTWARE\Vantaris\Actualizaciones: Url, Canal (estable|
//   pruebas), Desactivado (DWORD 1), IntervaloMinutos (DWORD). Para pruebas: VANTARIS_UPDATE_URL.
// El formato del manifiesto es el de lib/vantaris/update/manifest.dart.

#include "vantaris_update.h"

#include <winsock2.h>
#include <windows.h>
#include <bcrypt.h>
#include <iphlpapi.h>
#include <winhttp.h>

#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "vantaris_ed25519.h"

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")

namespace {

enum Exit { kAlDia = 0, kError = 1, kRechazada = 2, kPospuesta = 3, kHayVersion = 10, kLanzada = 20 };

std::wstring Widen(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring ExePath() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
  return std::wstring(buf, n);
}

std::wstring ExeDir() {
  auto p = ExePath();
  return p.substr(0, p.find_last_of(L'\\'));
}

std::wstring g_log_path;

void Log(const std::string& s) {
  if (g_log_path.empty()) g_log_path = ExeDir() + L"\\vantaris-actualizaciones.log";
  WIN32_FILE_ATTRIBUTE_DATA fa;
  if (GetFileAttributesExW(g_log_path.c_str(), GetFileExInfoStandard, &fa) && fa.nFileSizeLow > 1 << 20) {
    MoveFileExW(g_log_path.c_str(), (g_log_path + L".1").c_str(), MOVEFILE_REPLACE_EXISTING);
  }
  std::ofstream f(g_log_path, std::ios::app | std::ios::binary);
  std::time_t t = std::time(nullptr);
  char ts[32];
  std::tm tm;
  localtime_s(&tm, &t);
  std::strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
  f << ts << " [" << GetCurrentProcessId() << "] " << s << "\r\n";
}

// ------------------------------------------------------------------ vantaris-version.txt / registro

struct Config {
  std::string variante, version, canal = "estable", url = "https://soporte.vantaris.es/actualizaciones";
  long long build = 0;
  std::map<std::string, std::vector<unsigned char>> claves;
  bool desactivado = false;
  DWORD intervalo_min = 6 * 60;
};

std::vector<unsigned char> B64(const std::string& in) {
  static const std::string tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::vector<unsigned char> out;
  int val = 0, bits = -8;
  for (unsigned char c : in) {
    if (c == '=') break;
    auto pos = tbl.find((char)c);
    if (pos == std::string::npos) {
      if (c == '\r' || c == '\n' || c == ' ') continue;
      return {};
    }
    val = (val << 6) + (int)pos;
    bits += 6;
    if (bits >= 0) {
      out.push_back((unsigned char)((val >> bits) & 0xff));
      bits -= 8;
    }
  }
  return out;
}

std::string Trim(const std::string& s) {
  size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
  return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

bool RegStr(const wchar_t* name, std::string* out) {
  wchar_t buf[1024];
  DWORD sz = sizeof buf;
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Vantaris\\Actualizaciones", name, RRF_RT_REG_SZ,
                   nullptr, buf, &sz) != ERROR_SUCCESS)
    return false;
  *out = Narrow(buf);
  return true;
}

bool RegDword(const wchar_t* name, DWORD* out) {
  DWORD sz = sizeof(DWORD);
  return RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Vantaris\\Actualizaciones", name,
                      RRF_RT_REG_DWORD, nullptr, out, &sz) == ERROR_SUCCESS;
}

bool LoadConfig(Config* c) {
  std::ifstream f(ExeDir() + L"\\vantaris-version.txt", std::ios::binary);
  if (!f) return false;
  std::string line;
  while (std::getline(f, line)) {
    auto i = line.find('=');
    if (i == std::string::npos) continue;
    auto k = Trim(line.substr(0, i)), v = Trim(line.substr(i + 1));
    if (k == "variante") c->variante = v;
    else if (k == "version") c->version = v;
    else if (k == "build") c->build = _atoi64(v.c_str());
    else if (k == "canal") c->canal = v;
    else if (k == "url" && !v.empty()) c->url = v;
    else if (k.rfind("clave.", 0) == 0) {
      auto key = B64(v);
      if (key.size() == 32) c->claves[k.substr(6)] = key;
    }
  }
  std::string s;
  if (RegStr(L"Url", &s) && !s.empty()) c->url = s;
  if (RegStr(L"Canal", &s) && (s == "estable" || s == "pruebas")) c->canal = s;
  DWORD d;
  if (RegDword(L"Desactivado", &d)) c->desactivado = d != 0;
  if (RegDword(L"IntervaloMinutos", &d) && d >= 5) c->intervalo_min = d;
  wchar_t env[1024];
  if (GetEnvironmentVariableW(L"VANTARIS_UPDATE_URL", env, 1024) > 0) c->url = Narrow(env);
  while (!c->url.empty() && c->url.back() == '/') c->url.pop_back();
  return !c->variante.empty() && c->build > 0;
}

// ------------------------------------------------------------------ JSON mínimo

struct J {
  enum T { Null, Bool, Num, Str, Arr, Obj } t = Null;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<J> a;
  std::map<std::string, J> o;
  const J& operator[](const std::string& k) const {
    static J nul;
    auto it = o.find(k);
    return it == o.end() ? nul : it->second;
  }
};

struct Parser {
  const std::string& s;
  size_t i = 0;
  int depth = 0;
  explicit Parser(const std::string& str) : s(str) {}
  char at() const { return i < s.size() ? s[i] : 0; }
  void ws() { while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++; }
  bool lit(const char* w) {
    size_t n = strlen(w);
    if (s.compare(i, n, w) != 0) return false;
    i += n;
    return true;
  }
  static void utf8(std::string& o, unsigned cp) {
    if (cp < 0x80) o += (char)cp;
    else if (cp < 0x800) { o += (char)(0xc0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) { o += (char)(0xe0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3f)); o += (char)(0x80 | (cp & 0x3f)); }
    else { o += (char)(0xf0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3f)); o += (char)(0x80 | ((cp >> 6) & 0x3f)); o += (char)(0x80 | (cp & 0x3f)); }
  }
  bool str(std::string& o) {
    if (at() != '"') return false;
    i++;
    while (i < s.size() && s[i] != '"') {
      char c = s[i++];
      if (c != '\\') { o += c; continue; }
      if (i >= s.size()) return false;
      char e = s[i++];
      switch (e) {
        case 'n': o += '\n'; break;
        case 't': o += '\t'; break;
        case 'r': o += '\r'; break;
        case 'b': o += '\b'; break;
        case 'f': o += '\f'; break;
        case 'u': {
          if (i + 4 > s.size()) return false;
          unsigned cp = std::stoul(s.substr(i, 4), nullptr, 16);
          i += 4;
          if (cp >= 0xd800 && cp < 0xdc00 && i + 6 <= s.size() && s[i] == '\\' && s[i + 1] == 'u') {
            unsigned lo = std::stoul(s.substr(i + 2, 4), nullptr, 16);
            i += 6;
            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
          }
          utf8(o, cp);
          break;
        }
        default: o += e;
      }
    }
    if (i >= s.size()) return false;
    i++;
    return true;
  }
  bool val(J& v) {
    if (++depth > 20) return false;
    ws();
    if (i >= s.size()) return false;
    bool ok = true;
    char c = at();
    if (c == '{') {
      v.t = J::Obj;
      i++;
      ws();
      if (at() == '}') { i++; }
      else {
        while (ok) {
          ws();
          std::string k;
          if (!str(k)) return false;
          ws();
          if (at() != ':' || (i++, false)) return false;
          if (!val(v.o[k])) return false;
          ws();
          if (at() == ',') { i++; continue; }
          if (at() == '}') { i++; break; }
          return false;
        }
      }
    } else if (c == '[') {
      v.t = J::Arr;
      i++;
      ws();
      if (at() == ']') { i++; }
      else {
        while (true) {
          v.a.emplace_back();
          if (!val(v.a.back())) return false;
          ws();
          if (at() == ',') { i++; continue; }
          if (at() == ']') { i++; break; }
          return false;
        }
      }
    } else if (c == '"') {
      v.t = J::Str;
      ok = str(v.s);
    } else if (lit("true")) { v.t = J::Bool; v.b = true; }
    else if (lit("false")) { v.t = J::Bool; }
    else if (lit("null")) { v.t = J::Null; }
    else {
      size_t st = i;
      while (i < s.size() && (isdigit((unsigned char)s[i]) || at() == '-' || at() == '+' || at() == '.' || at() == 'e' || at() == 'E')) i++;
      if (st == i) return false;
      v.t = J::Num;
      v.n = strtod(s.substr(st, i - st).c_str(), nullptr);
    }
    depth--;
    return ok;
  }
};

bool ParseJson(const std::string& s, J* out) {
  try {
    Parser p(s);
    if (!p.val(*out)) return false;
    p.ws();
    return p.i == s.size();
  } catch (...) {
    return false;
  }
}

bool IsInt(const J& v) { return v.t == J::Num && v.n == (double)(long long)v.n; }

// ------------------------------------------------------------------ HTTP (WinHTTP) y SHA-256

struct Sha256 {
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE h = nullptr;
  Sha256() {
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0)
      BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0);
  }
  ~Sha256() {
    if (h) BCryptDestroyHash(h);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  }
  void Add(const void* d, size_t n) { BCryptHashData(h, (PUCHAR)d, (ULONG)n, 0); }
  std::string Hex() {
    unsigned char out[32];
    BCryptFinishHash(h, out, 32, 0);
    static const char* hx = "0123456789abcdef";
    std::string r;
    for (auto c : out) { r += hx[c >> 4]; r += hx[c & 15]; }
    return r;
  }
};

// GET de url. Si file no está vacío escribe ahí (y hashea), si no, al string. Límite de bytes.
bool HttpGet(const std::string& url_utf8, std::string* body, const std::wstring& file, unsigned long long limit,
             Sha256* sha, unsigned long long* got, int* status) {
  std::wstring url = Widen(url_utf8);
  URL_COMPONENTS uc = {sizeof uc};
  wchar_t host[256], path[2048];
  uc.lpszHostName = host; uc.dwHostNameLength = 256;
  uc.lpszUrlPath = path; uc.dwUrlPathLength = 2048;
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;
  bool https = uc.nScheme == INTERNET_SCHEME_HTTPS;
  HINTERNET ses = WinHttpOpen(L"Vantaris-Actualizador/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!ses) ses = WinHttpOpen(L"Vantaris-Actualizador/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!ses) return false;
  WinHttpSetTimeouts(ses, 15000, 15000, 30000, 60000);
  bool ok = false;
  HINTERNET con = WinHttpConnect(ses, host, uc.nPort, 0);
  HINTERNET req = con ? WinHttpOpenRequest(con, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                           WINHTTP_DEFAULT_ACCEPT_TYPES, https ? WINHTTP_FLAG_SECURE : 0)
                      : nullptr;
  HANDLE fh = INVALID_HANDLE_VALUE;
  if (req && WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
      WinHttpReceiveResponse(req, nullptr)) {
    DWORD code = 0, sz = sizeof code;
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &code, &sz, nullptr);
    *status = (int)code;
    if (code == 200) {
      if (!file.empty()) fh = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      ok = file.empty() || fh != INVALID_HANDLE_VALUE;
      std::vector<char> buf(64 * 1024);
      unsigned long long total = 0;
      while (ok) {
        DWORD n = 0;
        if (!WinHttpReadData(req, buf.data(), (DWORD)buf.size(), &n)) { ok = false; break; }
        if (n == 0) break;
        total += n;
        if (total > limit) { ok = false; break; }
        if (sha) sha->Add(buf.data(), n);
        if (fh != INVALID_HANDLE_VALUE) {
          DWORD w;
          if (!WriteFile(fh, buf.data(), n, &w, nullptr) || w != n) ok = false;
        } else if (body) {
          body->append(buf.data(), n);
        }
      }
      if (got) *got = total;
    }
  }
  if (fh != INVALID_HANDLE_VALUE) CloseHandle(fh);
  if (req) WinHttpCloseHandle(req);
  if (con) WinHttpCloseHandle(con);
  WinHttpCloseHandle(ses);
  return ok;
}

// ------------------------------------------------------------------ ¿hay asistencia en curso?

bool FreshHeartbeat() {
  wchar_t pd[MAX_PATH];
  if (!GetEnvironmentVariableW(L"ProgramData", pd, MAX_PATH)) wcscpy_s(pd, L"C:\\ProgramData");
  WIN32_FILE_ATTRIBUTE_DATA fa;
  std::wstring f = std::wstring(pd) + L"\\Vantaris\\sesion-activa";
  if (!GetFileAttributesExW(f.c_str(), GetFileExInfoStandard, &fa)) return false;
  FILETIME now;
  GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER a, b;
  a.LowPart = now.dwLowDateTime; a.HighPart = now.dwHighDateTime;
  b.LowPart = fa.ftLastWriteTime.dwLowDateTime; b.HighPart = fa.ftLastWriteTime.dwHighDateTime;
  return a.QuadPart < b.QuadPart + 60ULL * 10000000ULL;  // < 60 s
}

bool RelayConnection() {
  // Conexiones TCP establecidas al relay (21117) de procesos de este mismo programa.
  std::wstring me = ExePath();
  DWORD sz = 0;
  GetExtendedTcpTable(nullptr, &sz, FALSE, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
  std::vector<char> buf(sz + 4096);
  sz = (DWORD)buf.size();
  if (GetExtendedTcpTable(buf.data(), &sz, FALSE, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0) != NO_ERROR)
    return false;
  auto* t = (MIB_TCPTABLE_OWNER_PID*)buf.data();
  for (DWORD i = 0; i < t->dwNumEntries; i++) {
    auto& r = t->table[i];
    if (r.dwState != MIB_TCP_STATE_ESTAB || ((r.dwRemotePort >> 8) | ((r.dwRemotePort & 0xff) << 8)) != 21117) continue;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, r.dwOwningPid);
    if (!p) continue;
    wchar_t img[MAX_PATH * 2];
    DWORD n = MAX_PATH * 2;
    bool same = QueryFullProcessImageNameW(p, 0, img, &n) && _wcsicmp(img, me.c_str()) == 0;
    CloseHandle(p);
    if (same) return true;
  }
  return false;
}

bool SessionActive() {
  if (FreshHeartbeat()) { Log("hay asistencia en curso (latido del gestor de conexiones)"); return true; }
  if (RelayConnection()) { Log("hay asistencia en curso (conexión por el relay)"); return true; }
  return false;
}

// ------------------------------------------------------------------ utilidades de ficheros/procesos

void RemoveTree(const std::wstring& dir) {
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      std::wstring n = fd.cFileName;
      if (n == L"." || n == L"..") continue;
      std::wstring p = dir + L"\\" + n;
      if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
        RemoveTree(p);
      else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        RemoveDirectoryW(p.c_str());
      else {
        SetFileAttributesW(p.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(p.c_str());
      }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
  RemoveDirectoryW(dir.c_str());
}

DWORD RunWait(const std::wstring& cmd, DWORD timeout_ms) {
  STARTUPINFOW si = {sizeof si};
  PROCESS_INFORMATION pi = {};
  std::wstring c = cmd;
  if (!CreateProcessW(nullptr, &c[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    return (DWORD)-1;
  DWORD code = (DWORD)-1;
  if (WaitForSingleObject(pi.hProcess, timeout_ms) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
  else TerminateProcess(pi.hProcess, 1);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return code;
}

bool LaunchDetached(const std::wstring& cmd) {
  STARTUPINFOW si = {sizeof si};
  PROCESS_INFORMATION pi = {};
  for (DWORD extra : {(DWORD)CREATE_BREAKAWAY_FROM_JOB, (DWORD)0}) {
    std::wstring c = cmd;
    if (CreateProcessW(nullptr, &c[0], nullptr, nullptr, FALSE,
                       DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | extra, nullptr, nullptr, &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      return true;
    }
  }
  return false;
}

std::wstring SysDir() {
  wchar_t b[MAX_PATH];
  GetSystemDirectoryW(b, MAX_PATH);
  return b;
}

// ------------------------------------------------------------------ la actualización

int Run(bool only_check, bool no_install) {
  Config c;
  if (!LoadConfig(&c)) {
    Log("sin vantaris-version.txt válido junto al programa: no se actualiza");
    return kError;
  }
  if (c.desactivado) {
    Log("desactivado por el registro");
    return kAlDia;
  }
  if (c.claves.empty()) {
    Log("sin claves públicas: no se acepta ninguna actualización");
    return kError;
  }
  const std::string url = c.url + "/" + c.canal + "/windows-" + c.variante + ".json";
  std::string body;
  int status = 0;
  if (!HttpGet(url, &body, L"", 64 * 1024, nullptr, nullptr, &status)) {
    Log("no se pudo consultar " + url + " (HTTP " + std::to_string(status) + ")");
    return status == 404 ? kAlDia : kError;
  }
  J env, m;
  if (!ParseJson(body, &env) || env["formato"].n != 1 || env["clave"].t != J::Str) {
    Log("RECHAZADA: manifiesto ilegible (" + url + ")");
    return kRechazada;
  }
  auto key = c.claves.find(env["clave"].s);
  if (key == c.claves.end()) {
    Log("RECHAZADA: clave desconocida «" + env["clave"].s + "»");
    return kRechazada;
  }
  auto carga = B64(env["carga"].s), firma = B64(env["firma"].s);
  if (carga.empty() || firma.size() != 64 ||
      !VantarisEd25519Verify(key->second.data(), carga.data(), carga.size(), firma.data())) {
    Log("RECHAZADA: FIRMA NO VÁLIDA (" + url + ")");
    return kRechazada;
  }
  if (!ParseJson(std::string(carga.begin(), carga.end()), &m) || m["formato"].n != 1 ||
      m["producto"].s != "vantaris") {
    Log("RECHAZADA: carga firmada ilegible o de otro producto");
    return kRechazada;
  }
  if (m["variante"].s != c.variante || m["plataforma"].s != "windows" || m["canal"].s != c.canal) {
    Log("RECHAZADA: el manifiesto es de " + m["plataforma"].s + "-" + m["variante"].s + "/" + m["canal"].s);
    return kRechazada;
  }
  if (!IsInt(m["build"])) { Log("RECHAZADA: build no válido"); return kRechazada; }
  long long build = (long long)m["build"].n;
  if (build <= c.build) {
    Log("al día (instalada " + std::to_string(c.build) + ", publicada " + std::to_string(build) + ")");
    return kAlDia;
  }
  const J& p = m["paquetes"]["x64"];
  if (p["url"].t != J::Str || p["sha256"].s.size() != 64 || !IsInt(p["tamano"]) || p["tamano"].n <= 0) {
    Log("RECHAZADA: la versión " + std::to_string(build) + " no trae paquete x64 válido");
    return kRechazada;
  }
  Log("VERSIÓN NUEVA " + m["version"].s + " build " + std::to_string(build) + " (instalada " +
      std::to_string(c.build) + "), firma OK");
  if (only_check) return kHayVersion;
  if (SessionActive()) return kPospuesta;

  std::string purl = p["url"].s;
  if (purl.rfind("http://", 0) != 0 && purl.rfind("https://", 0) != 0) purl = url.substr(0, url.rfind('/') + 1) + purl;
  // Carpeta dentro de la del programa: en una instalación, solo administradores pueden escribir.
  const std::wstring stage = ExeDir() + L"\\vantaris-actualizacion";
  RemoveTree(stage);
  CreateDirectoryW(stage.c_str(), nullptr);
  const std::wstring zip = stage + L"\\paquete.zip", dir = stage + L"\\nueva";
  const auto size = (unsigned long long)p["tamano"].n;
  Sha256 sha;
  unsigned long long got = 0;
  if (!HttpGet(purl, nullptr, zip, size, &sha, &got, &status) || got != size) {
    Log("no se pudo bajar el paquete " + purl + " (HTTP " + std::to_string(status) + ", " + std::to_string(got) +
        " de " + std::to_string(size) + " bytes)");
    RemoveTree(stage);
    return kError;
  }
  std::string hex = sha.Hex();
  if (hex != p["sha256"].s) {
    Log("RECHAZADA: EL HASH DEL PAQUETE NO CUADRA (" + hex + ")");
    RemoveTree(stage);
    return kRechazada;
  }
  Log("paquete bajado y comprobado (sha256 " + hex + ")");
  CreateDirectoryW(dir.c_str(), nullptr);
  DWORD rc = RunWait(L"\"" + SysDir() + L"\\tar.exe\" -xf \"" + zip + L"\" -C \"" + dir + L"\"", 10 * 60 * 1000);
  if (rc != 0) {
    Log("tar.exe falló (" + std::to_string((long)rc) + "), pruebo con PowerShell");
    rc = RunWait(L"\"" + SysDir() + L"\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive "
                 L"-Command \"Expand-Archive -LiteralPath '" + zip + L"' -DestinationPath '" + dir + L"' -Force\"",
                 10 * 60 * 1000);
  }
  std::wstring exe;
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\vantaris-*.exe").c_str(), &fd);
  if (h != INVALID_HANDLE_VALUE) {
    exe = dir + L"\\" + fd.cFileName;
    FindClose(h);
  }
  if (rc != 0 || exe.empty()) {
    Log("no se pudo descomprimir el paquete o no trae el programa");
    RemoveTree(stage);
    return kError;
  }
  if (no_install) {
    Log("--sin-instalar: listo para instalar " + Narrow(exe));
    return kAlDia;
  }
  if (SessionActive()) return kPospuesta;
  if (!LaunchDetached(L"\"" + exe + L"\" --update")) {
    Log("no se pudo lanzar la actualización (" + std::to_string(GetLastError()) + ")");
    return kError;
  }
  Log("lanzado «--update» de la build " + std::to_string(build));
  return kLanzada;
}

void Scheduler() {
  Config c;
  LoadConfig(&c);
  // Primera vuelta entre 10 y 30 min después de arrancar el servicio (que no bajen todos a la vez).
  std::this_thread::sleep_for(std::chrono::minutes(10 + (GetTickCount() % 21)));
  const std::wstring cmd = L"\"" + ExePath() + L"\" --vantaris-actualizar";
  while (true) {
    Config now;
    LoadConfig(&now);
    RunWait(cmd, 60 * 60 * 1000);
    std::this_thread::sleep_for(std::chrono::minutes(now.intervalo_min));
  }
}

}  // namespace

int VantarisUpdateMain(const std::vector<std::string>& args) {
  if (args.empty() || args[0] != "--vantaris-actualizar") return -1;
  bool only_check = false, no_install = false;
  for (auto& a : args) {
    if (a == "--comprobar") only_check = true;
    if (a == "--sin-instalar") no_install = true;
  }
  int r = Run(only_check, no_install);
  Log("fin (" + std::to_string(r) + ")");
  return r;
}

void VantarisUpdateStartScheduler(const std::vector<std::string>& args) {
  if (args.empty() || args[0] != "--service") return;
  Config c;
  if (!LoadConfig(&c) || c.variante != "soporte") return;  // el técnico se actualiza preguntando (Dart)
  std::thread(Scheduler).detach();
}
