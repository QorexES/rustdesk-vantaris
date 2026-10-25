#include "vantaris_diag.h"

// winsock2 antes que windows.h (lo pide iphlpapi).
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <cstdio>
#include <string>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

namespace vantaris_diag {
namespace {

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
  return s;
}

std::string Esc(const std::string& s) {
  std::string o;
  for (char c : s) {
    if (c == '"' || c == '\\') {
      o += '\\';
      o += c;
    } else if ((unsigned char)c < 0x20) {
      o += ' ';
    } else {
      o += c;
    }
  }
  return o;
}

std::wstring RegString(const wchar_t* name) {
  wchar_t buf[256];
  DWORD size = sizeof(buf);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", name,
                   RRF_RT_REG_SZ, nullptr, buf, &size) == ERROR_SUCCESS) {
    return buf;
  }
  return L"";
}

std::string OsName() {
  typedef LONG(WINAPI * RtlGetVersionFn)(PRTL_OSVERSIONINFOW);
  RTL_OSVERSIONINFOW v = {sizeof(v)};
  if (auto f = (RtlGetVersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion")) {
    f(&v);
  }
  std::wstring product = RegString(L"ProductName");
  // Windows 11 sigue diciendo Windows 10 en el registro: lo delata el numero de compilacion.
  if (v.dwBuildNumber >= 22000) {
    auto p = product.find(L"Windows 10");
    if (p != std::wstring::npos) product.replace(p, 10, L"Windows 11");
  }
  if (product.empty()) product = L"Windows";
  std::wstring display = RegString(L"DisplayVersion");
  char num[64];
  snprintf(num, sizeof(num), " (%lu.%lu.%lu)", v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber);
  std::string out = Utf8(product);
  if (!display.empty()) out += " " + Utf8(display);
  return out + num;
}

std::string Network() {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buf(size);
  ULONG flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                GAA_FLAG_SKIP_DNS_SERVER;
  auto* a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
  ULONG r = GetAdaptersAddresses(AF_INET, flags, nullptr, a, &size);
  if (r == ERROR_BUFFER_OVERFLOW) {
    buf.resize(size);
    a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
    r = GetAdaptersAddresses(AF_INET, flags, nullptr, a, &size);
  }
  if (r != NO_ERROR) return "{\"tipo\":\"desconocida\"}";
  // La red buena es la que esta levantada y tiene puerta de enlace (la que sale a internet).
  for (auto* p = a; p; p = p->Next) {
    if (p->OperStatus != IfOperStatusUp || p->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
    if (!p->FirstGatewayAddress) continue;
    const char* tipo = p->IfType == IF_TYPE_IEEE80211 ? "wifi"
                       : p->IfType == IF_TYPE_ETHERNET_CSMACD ? "cable (ethernet)"
                       : p->IfType == IF_TYPE_WWANPP || p->IfType == IF_TYPE_WWANPP2 ? "datos m\xc3\xb3viles"
                                                                                       : "otra";
    std::string ip;
    for (auto* u = p->FirstUnicastAddress; u; u = u->Next) {
      if (u->Address.lpSockaddr->sa_family != AF_INET) continue;
      char s[INET_ADDRSTRLEN] = {0};
      auto* in = reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr);
      inet_ntop(AF_INET, &in->sin_addr, s, sizeof(s));
      ip = s;
      break;
    }
    return "{\"tipo\":\"" + std::string(tipo) + "\",\"ip\":\"" + Esc(ip) + "\",\"nombre\":\"" +
           Esc(Utf8(p->FriendlyName ? p->FriendlyName : L"")) + "\"}";
  }
  return "{\"tipo\":\"sin red\"}";
}

}  // namespace

std::string SysInfoJson() {
  std::string o = "{\"so\":\"" + Esc(OsName()) + "\"";
  SYSTEM_POWER_STATUS ps;
  if (GetSystemPowerStatus(&ps)) {
    // 128 = sin bateria (sobremesa), 255 = desconocido.
    if (ps.BatteryFlag == 128 || ps.BatteryFlag == 255 || ps.BatteryLifePercent == 255) {
      o += ",\"sinBateria\":true";
    } else {
      o += ",\"bateria\":" + std::to_string(ps.BatteryLifePercent);
      o += std::string(",\"cargando\":") + ((ps.BatteryFlag & 8) ? "true" : "false");
      o += std::string(",\"enchufado\":") + (ps.ACLineStatus == 1 ? "true" : "false");
    }
  }
  wchar_t win[MAX_PATH] = L"C:\\";
  if (GetWindowsDirectoryW(win, MAX_PATH) >= 3) win[3] = 0;
  ULARGE_INTEGER freeUser, total, freeAll;
  if (GetDiskFreeSpaceExW(win, &freeUser, &total, &freeAll)) {
    o += ",\"discoLibreMb\":" + std::to_string(freeUser.QuadPart / (1024 * 1024));
    o += ",\"discoTotalMb\":" + std::to_string(total.QuadPart / (1024 * 1024));
  }
  MEMORYSTATUSEX m = {sizeof(m)};
  if (GlobalMemoryStatusEx(&m)) {
    o += ",\"memLibreMb\":" + std::to_string(m.ullAvailPhys / (1024 * 1024));
    o += ",\"memTotalMb\":" + std::to_string(m.ullTotalPhys / (1024 * 1024));
  }
  o += ",\"red\":" + Network();
  return o + "}";
}

}  // namespace vantaris_diag
