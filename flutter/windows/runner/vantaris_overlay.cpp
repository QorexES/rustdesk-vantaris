#include "vantaris_overlay.h"

#include <windows.h>
#include <objidl.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <sstream>
#include <vector>

// gdiplus.h usa min/max y el runner compila con NOMINMAX.
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus
#include <gdiplus.h>

#pragma comment(lib, "gdiplus.lib")

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

// Reglas de dibujo: las mismas que flutter/lib/vantaris/scene.dart (lo que ve el tecnico) y
// VantarisDrawOverlay.kt (Android). Si se cambia algo, cambiarlo en los tres.
namespace vantaris_overlay {
namespace {

constexpr DWORD kHoldMs = 6000;      // visible tras terminar (trazos y formas)
constexpr DWORD kHoldMarkMs = 20000; // numeros y textos
constexpr DWORD kFadeMs = 1200;
constexpr DWORD kLaserMs = 1500;     // el laser se apaga solo si deja de llegar posicion
constexpr DWORD kTrailMs = 450;      // estela del laser
constexpr UINT_PTR kTimerId = 1;
constexpr UINT kFrameMs = 40;
const wchar_t kClassName[] = L"VantarisOverlay";

enum class Kind { kStroke, kShape, kNumber, kText };

struct Item {
  Kind kind = Kind::kStroke;
  Gdiplus::ARGB color = 0xFFE53935;
  int width_permille = 6;
  std::vector<Gdiplus::PointF> points;  // normalizados 0..1
  char shape = 'I';                     // A flecha, R rectangulo, O elipse, T triangulo, I linea
  std::wstring label;                   // numero o texto
  DWORD ended_at = 0;
  DWORD hold_ms = kHoldMs;
};

struct Laser {
  bool visible = false;
  float x = 0, y = 0;
  DWORD updated_at = 0;
};

struct TrailPoint {
  DWORD t;
  float x, y;
};

HWND g_hwnd = nullptr;
ULONG_PTR g_gdiplus_token = 0;
RECT g_target = {0, 0, 0, 0};  // pantalla remota que ve el tecnico, en pixeles fisicos
std::map<std::string, Item> g_items;
Laser g_laser;
std::vector<TrailPoint> g_trail;
bool g_focus_on = false;
Gdiplus::RectF g_focus;  // normalizado
bool g_timer_on = false;
// Modo "no tocar": el bloqueo real es el de RustDesk; aqui solo el aviso. Se quita solo si el
// tecnico deja de confirmarlo (ver flutter/lib/vantaris/guard.dart).
constexpr DWORD kBlockWatchdogMs = 20000;
bool g_block_on = false;
DWORD g_block_beat = 0;
// Grabacion para el resumen (R 1 / R 0, con latido del tecnico igual que el bloqueo).
bool g_rec_on = false;
DWORD g_rec_beat = 0;

void Render();

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_TIMER:
      if (wp == kTimerId) Render();
      return 0;
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}

void DefaultTarget() {
  if (g_target.right > g_target.left) return;
  g_target = {0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
}

bool StartGdiplus() {
  if (g_gdiplus_token) return true;
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr) != Gdiplus::Ok) {
    g_gdiplus_token = 0;
    return false;
  }
  return true;
}

bool EnsureWindow() {
  if (g_hwnd) return true;
  if (!StartGdiplus()) return false;
  HINSTANCE inst = GetModuleHandle(nullptr);
  WNDCLASSEXW wc = {sizeof(wc)};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = inst;
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);  // si ya existe falla sin mas
  DefaultTarget();
  g_hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClassName, L"Vantaris", WS_POPUP, g_target.left, g_target.top,
      g_target.right - g_target.left, g_target.bottom - g_target.top, nullptr, nullptr, inst,
      nullptr);
  if (!g_hwnd) return false;
  // Windows 10 2004+: no aparece en la captura de pantalla (ni en la del tecnico).
  // VANTARIS_OVERLAY_CAPTURABLE=1 la deja capturable, solo para probar el pintado.
  wchar_t capturable[4] = {};
  if (GetEnvironmentVariableW(L"VANTARIS_OVERLAY_CAPTURABLE", capturable, 4) == 0 ||
      capturable[0] != L'1') {
    SetWindowDisplayAffinity(g_hwnd, WDA_EXCLUDEFROMCAPTURE);
  }
  return true;
}

bool Animating(DWORD now) {
  for (const auto& kv : g_items) {
    if (kv.second.ended_at) return true;
  }
  if (g_block_on || g_rec_on) return true;
  return g_laser.visible && now - g_laser.updated_at < kLaserMs;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  const int n =
      MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

// base64url sin relleno (orden X).
std::string Base64UrlDecode(const std::string& in) {
  auto val = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-' || c == '+') return 62;
    if (c == '_' || c == '/') return 63;
    return -1;
  };
  std::string out;
  int buf = 0, bits = 0;
  for (char c : in) {
    const int v = val(c);
    if (v < 0) continue;
    buf = ((buf << 6) | v) & 0xFFFFFF;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<char>((buf >> bits) & 0xFF));
    }
  }
  return out;
}

Gdiplus::Color WithAlpha(Gdiplus::ARGB c, float alpha) {
  const BYTE a =
      static_cast<BYTE>(((c >> 24) & 0xFF) * std::clamp(alpha, 0.0f, 1.0f));
  return Gdiplus::Color(a, static_cast<BYTE>((c >> 16) & 0xFF),
                        static_cast<BYTE>((c >> 8) & 0xFF), static_cast<BYTE>(c & 0xFF));
}

float Luminance(Gdiplus::ARGB c) {
  auto ch = [](int v) {
    const float s = v / 255.0f;
    return s <= 0.03928f ? s / 12.92f : std::pow((s + 0.055f) / 1.055f, 2.4f);
  };
  return 0.2126f * ch((c >> 16) & 0xFF) + 0.7152f * ch((c >> 8) & 0xFF) +
         0.0722f * ch(c & 0xFF);
}

void AddRoundRect(Gdiplus::GraphicsPath* path, const Gdiplus::RectF& r, float radius) {
  const float d = std::max(0.1f, std::min({radius * 2, r.Width, r.Height}));
  path->AddArc(r.X, r.Y, d, d, 180, 90);
  path->AddArc(r.GetRight() - d, r.Y, d, d, 270, 90);
  path->AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0, 90);
  path->AddArc(r.X, r.GetBottom() - d, d, d, 90, 90);
  path->CloseFigure();
}

void DrawShape(Gdiplus::Graphics& g, Gdiplus::Pen& pen, char kind, Gdiplus::PointF a,
               Gdiplus::PointF b, float sw) {
  const Gdiplus::RectF r(std::min(a.X, b.X), std::min(a.Y, b.Y), std::abs(b.X - a.X),
                         std::abs(b.Y - a.Y));
  switch (kind) {
    case 'R': {
      Gdiplus::GraphicsPath path;
      AddRoundRect(&path, r, sw);
      g.DrawPath(&pen, &path);
      break;
    }
    case 'O':
      g.DrawEllipse(&pen, r);
      break;
    case 'T': {
      Gdiplus::PointF tri[3] = {Gdiplus::PointF(r.X + r.Width / 2, r.Y),
                                Gdiplus::PointF(r.GetRight(), r.GetBottom()),
                                Gdiplus::PointF(r.X, r.GetBottom())};
      g.DrawPolygon(&pen, tri, 3);
      break;
    }
    case 'A': {
      const float dx = b.X - a.X, dy = b.Y - a.Y;
      const float len = std::hypot(dx, dy);
      if (len < 1) break;
      const float head = std::min(len * 0.6f, std::max(sw * 4, 14.0f));
      const float ux = dx / len, uy = dy / len;
      // La linea acaba en la base de la punta para que no asome por delante.
      g.DrawLine(&pen, a, Gdiplus::PointF(b.X - ux * head * 0.8f, b.Y - uy * head * 0.8f));
      const float ang = 0.5f, c = std::cos(ang), sn = std::sin(ang);
      Gdiplus::PointF tip[3] = {
          b, Gdiplus::PointF(b.X - head * (ux * c - uy * sn), b.Y - head * (uy * c + ux * sn)),
          Gdiplus::PointF(b.X - head * (ux * c + uy * sn), b.Y - head * (uy * c - ux * sn))};
      Gdiplus::Color pc;
      pen.GetColor(&pc);
      Gdiplus::SolidBrush brush(pc);
      g.FillPolygon(&brush, tip, 3);
      break;
    }
    default:
      g.DrawLine(&pen, a, b);
  }
}

void DrawNumber(Gdiplus::Graphics& g, Gdiplus::PointF c, const std::wstring& label,
                Gdiplus::ARGB color, float alpha, float short_side) {
  const float r = std::max(14.0f, short_side * 0.022f);
  Gdiplus::SolidBrush ring(WithAlpha(0xF2FFFFFF, alpha));
  g.FillEllipse(&ring, c.X - r * 1.15f, c.Y - r * 1.15f, r * 2.3f, r * 2.3f);
  Gdiplus::SolidBrush disc(WithAlpha(color, alpha));
  g.FillEllipse(&disc, c.X - r, c.Y - r, r * 2, r * 2);
  Gdiplus::FontFamily family(L"Segoe UI");
  Gdiplus::Font font(&family, r * 1.15f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::SolidBrush text(
      WithAlpha(Luminance(color) > 0.5f ? 0xFF111111 : 0xFFFFFFFF, alpha));
  Gdiplus::StringFormat fmt;
  fmt.SetAlignment(Gdiplus::StringAlignmentCenter);
  fmt.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  g.DrawString(label.c_str(), -1, &font, Gdiplus::RectF(c.X - r, c.Y - r, r * 2, r * 2),
               &fmt, &text);
}

void DrawLabel(Gdiplus::Graphics& g, Gdiplus::PointF at, const std::wstring& label,
               Gdiplus::ARGB color, float alpha, float short_side) {
  if (label.empty()) return;
  const float size = std::max(14.0f, short_side * 0.026f);
  Gdiplus::FontFamily family(L"Segoe UI");
  Gdiplus::Font font(&family, size, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::RectF bounds;
  g.MeasureString(label.c_str(), -1, &font, Gdiplus::RectF(0, 0, short_side * 0.9f, 10000),
                  &bounds);
  const float pad = size * 0.4f;
  const Gdiplus::RectF box(at.X, at.Y - bounds.Height / 2 - pad, bounds.Width + pad * 2,
                           bounds.Height + pad * 2);
  Gdiplus::GraphicsPath path;
  AddRoundRect(&path, box, pad);
  Gdiplus::SolidBrush bg(Gdiplus::Color(static_cast<BYTE>(0.78f * alpha * 255), 0, 0, 0));
  g.FillPath(&bg, &path);
  Gdiplus::SolidBrush text(WithAlpha(color, alpha));
  g.DrawString(label.c_str(), -1, &font,
               Gdiplus::RectF(at.X + pad, at.Y - bounds.Height / 2, bounds.Width + 1,
                              bounds.Height),
               nullptr, &text);
}

void Render() {
  if (!g_hwnd) return;
  const DWORD now = GetTickCount();

  // Caducar elementos y laser.
  for (auto it = g_items.begin(); it != g_items.end();) {
    if (it->second.ended_at && now - it->second.ended_at > it->second.hold_ms + kFadeMs) {
      it = g_items.erase(it);
    } else {
      ++it;
    }
  }
  if (g_laser.visible && now - g_laser.updated_at >= kLaserMs) g_laser.visible = false;
  if (!g_laser.visible) g_trail.clear();
  g_trail.erase(std::remove_if(g_trail.begin(), g_trail.end(),
                               [now](const TrailPoint& p) { return now - p.t > kTrailMs; }),
                g_trail.end());

  if (g_block_on && now - g_block_beat > kBlockWatchdogMs) g_block_on = false;
  if (g_rec_on && now - g_rec_beat > kBlockWatchdogMs) g_rec_on = false;

  if (g_items.empty() && !g_laser.visible && !g_focus_on && !g_block_on && !g_rec_on) {
    ShowWindow(g_hwnd, SW_HIDE);
    if (g_timer_on) KillTimer(g_hwnd, kTimerId);
    g_timer_on = false;
    return;
  }

  const int w = g_target.right - g_target.left;
  const int h = g_target.bottom - g_target.top;
  if (w <= 0 || h <= 0) return;
  const float short_side = static_cast<float>(std::min(w, h));

  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // de arriba abajo
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP dib = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib) {
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return;
  }
  HGDIOBJ old = SelectObject(mem, dib);
  {
    // Alfa premultiplicado, que es lo que espera UpdateLayeredWindow.
    Gdiplus::Bitmap canvas(w, h, w * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(bits));
    Gdiplus::Graphics g(&canvas);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));

    if (g_focus_on) {
      const Gdiplus::RectF hole(g_focus.X * w, g_focus.Y * h, g_focus.Width * w,
                                g_focus.Height * h);
      Gdiplus::GraphicsPath dim(Gdiplus::FillModeAlternate);
      dim.AddRectangle(Gdiplus::RectF(0, 0, static_cast<float>(w), static_cast<float>(h)));
      AddRoundRect(&dim, hole, 8);
      Gdiplus::SolidBrush dark(Gdiplus::Color(0x8C, 0, 0, 0));
      g.FillPath(&dark, &dim);
      Gdiplus::GraphicsPath border;
      AddRoundRect(&border, hole, 8);
      Gdiplus::Pen teal(Gdiplus::Color(255, 0x03, 0xB5, 0xA5),
                        std::max(2.0f, short_side * 0.004f));
      g.DrawPath(&teal, &border);
    }

    for (const auto& kv : g_items) {
      const Item& s = kv.second;
      if (s.points.empty()) continue;
      float alpha = 1.0f;
      if (s.ended_at) {
        const DWORD age = now - s.ended_at;
        if (age > s.hold_ms) alpha = 1.0f - static_cast<float>(age - s.hold_ms) / kFadeMs;
      }
      const float sw = std::max(2.0f, short_side * s.width_permille / 1000.0f);
      Gdiplus::Pen pen(WithAlpha(s.color, alpha), sw);
      pen.SetStartCap(Gdiplus::LineCapRound);
      pen.SetEndCap(Gdiplus::LineCapRound);
      pen.SetLineJoin(Gdiplus::LineJoinRound);
      const Gdiplus::PointF p0(s.points[0].X * w, s.points[0].Y * h);
      switch (s.kind) {
        case Kind::kStroke: {
          std::vector<Gdiplus::PointF> px;
          px.reserve(s.points.size() + 1);
          for (const auto& p : s.points) px.emplace_back(p.X * w, p.Y * h);
          if (px.size() == 1) px.emplace_back(px[0].X + 0.5f, px[0].Y);
          g.DrawLines(&pen, px.data(), static_cast<INT>(px.size()));
          break;
        }
        case Kind::kShape:
          if (s.points.size() >= 2) {
            DrawShape(g, pen, s.shape, p0,
                      Gdiplus::PointF(s.points[1].X * w, s.points[1].Y * h), sw);
          }
          break;
        case Kind::kNumber:
          DrawNumber(g, p0, s.label, s.color, alpha, short_side);
          break;
        case Kind::kText:
          DrawLabel(g, p0, s.label, s.color, alpha, short_side);
          break;
      }
    }

    if (g_rec_on) {
      const float size = std::max(13.0f, short_side * 0.018f);
      Gdiplus::FontFamily family(L"Segoe UI");
      Gdiplus::Font font(&family, size, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      const wchar_t* t = L"\u25CF  Se est\u00e1 grabando el audio de esta asistencia para hacer un resumen";
      Gdiplus::RectF b;
      g.MeasureString(t, -1, &font, Gdiplus::PointF(0, 0), &b);
      const float pad = size * 0.6f;
      const Gdiplus::RectF card((w - b.Width) / 2 - pad, size * 0.8f, b.Width + pad * 2,
                                b.Height + pad);
      Gdiplus::GraphicsPath path;
      AddRoundRect(&path, card, card.Height / 2);
      Gdiplus::SolidBrush bg(Gdiplus::Color(230, 0x15, 0x1B, 0x26));
      g.FillPath(&bg, &path);
      Gdiplus::SolidBrush red(Gdiplus::Color(255, 0xFF, 0x6B, 0x6B));
      g.DrawString(t, -1, &font, Gdiplus::PointF(card.X + pad, card.Y + pad / 2), &red);
    }

    if (g_block_on) {
      const float size = std::max(16.0f, short_side * 0.024f);
      Gdiplus::FontFamily family(L"Segoe UI");
      Gdiplus::Font title(&family, size, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      Gdiplus::Font body(&family, size * 0.8f, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      const wchar_t* t1 = L"Un t\u00e9cnico de Vantaris est\u00e1 trabajando en este equipo";
      const wchar_t* t2 = L"Por favor, no toque el rat\u00f3n ni el teclado hasta que termine.";
      Gdiplus::RectF b1, b2;
      g.MeasureString(t1, -1, &title, Gdiplus::PointF(0, 0), &b1);
      g.MeasureString(t2, -1, &body, Gdiplus::PointF(0, 0), &b2);
      const float pad = size * 0.8f;
      const float cw = std::max(b1.Width, b2.Width) + pad * 2;
      const float ch = b1.Height + b2.Height + pad * 2;
      const Gdiplus::RectF card((w - cw) / 2, h - ch - size * 3, cw, ch);
      Gdiplus::GraphicsPath path;
      AddRoundRect(&path, card, size * 0.7f);
      Gdiplus::SolidBrush bg(Gdiplus::Color(240, 0x15, 0x1B, 0x26));
      g.FillPath(&bg, &path);
      Gdiplus::Pen border(Gdiplus::Color(255, 0x03, 0xB5, 0xA5), 2.0f);
      g.DrawPath(&border, &path);
      Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
      Gdiplus::SolidBrush grey(Gdiplus::Color(255, 0xCF, 0xD8, 0xDC));
      g.DrawString(t1, -1, &title, Gdiplus::PointF(card.X + (cw - b1.Width) / 2, card.Y + pad), &white);
      g.DrawString(t2, -1, &body,
                   Gdiplus::PointF(card.X + (cw - b2.Width) / 2, card.Y + pad + b1.Height), &grey);
    }

    if (g_laser.visible) {
      for (size_t i = 1; i < g_trail.size(); ++i) {
        const float t = std::clamp(
            1.0f - static_cast<float>(now - g_trail[i].t) / kTrailMs, 0.0f, 1.0f);
        Gdiplus::Pen tp(Gdiplus::Color(static_cast<BYTE>(0.55f * t * 255), 255, 40, 40),
                        std::max(3.0f, short_side * 0.008f) * std::max(0.3f, t));
        tp.SetStartCap(Gdiplus::LineCapRound);
        tp.SetEndCap(Gdiplus::LineCapRound);
        g.DrawLine(&tp, g_trail[i - 1].x * w, g_trail[i - 1].y * h, g_trail[i].x * w,
                   g_trail[i].y * h);
      }
      const float cx = g_laser.x * w, cy = g_laser.y * h;
      const float r = std::max(6.0f, short_side * 0.009f);
      Gdiplus::SolidBrush halo(Gdiplus::Color(70, 255, 40, 40));
      g.FillEllipse(&halo, cx - r * 2.2f, cy - r * 2.2f, r * 4.4f, r * 4.4f);
      Gdiplus::SolidBrush core(Gdiplus::Color(235, 255, 30, 30));
      g.FillEllipse(&core, cx - r, cy - r, r * 2, r * 2);
      Gdiplus::SolidBrush dot(Gdiplus::Color(255, 255, 220, 220));
      g.FillEllipse(&dot, cx - r * 0.35f, cy - r * 0.35f, r * 0.7f, r * 0.7f);
    }
  }

  POINT dst = {g_target.left, g_target.top};
  SIZE size = {w, h};
  POINT src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_hwnd, screen, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);
  SelectObject(mem, old);
  DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);

  // Encima de todo, tambien de un TPV a pantalla completa que se haya puesto "siempre visible".
  SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);

  const bool animating = Animating(now);
  if (animating && !g_timer_on) {
    SetTimer(g_hwnd, kTimerId, kFrameMs, nullptr);
    g_timer_on = true;
  } else if (!animating && g_timer_on) {
    KillTimer(g_hwnd, kTimerId);
    g_timer_on = false;
  }
}

bool ParsePoint(const std::string& tok, float* x, float* y) {
  const auto comma = tok.find(',');
  if (comma == std::string::npos) return false;
  try {
    *x = std::stof(tok.substr(0, comma)) / 10000.0f;
    *y = std::stof(tok.substr(comma + 1)) / 10000.0f;
  } catch (...) {
    return false;
  }
  return true;
}

Gdiplus::ARGB ParseColor(const std::string& argb) {
  try {
    return static_cast<Gdiplus::ARGB>(std::stoul(argb, nullptr, 16));
  } catch (...) {
    return 0xFFE53935;
  }
}

void Apply(const std::string& line) {
  std::istringstream in(line);
  std::string cmd;
  if (!(in >> cmd)) return;
  const DWORD now = GetTickCount();
  if (cmd == "C") {
    g_items.clear();
    g_focus_on = false;
    g_laser.visible = false;
  } else if (cmd == "Z") {
    std::string id;
    in >> id;
    g_items.erase(id);
  } else if (cmd == "E") {
    std::string id;
    in >> id;
    auto it = g_items.find(id);
    if (it != g_items.end()) {
      it->second.ended_at = now;
      DWORD ms;
      if (in >> ms) it->second.hold_ms = ms;
    }
  } else if (cmd == "P") {
    std::string id, argb;
    int width = 6;
    if (!(in >> id >> argb >> width)) return;
    Item& s = g_items[id];
    s.kind = Kind::kStroke;
    s.color = ParseColor(argb);
    s.width_permille = width;
    std::string tok;
    float x, y;
    while (in >> tok) {
      if (ParsePoint(tok, &x, &y)) s.points.emplace_back(x, y);
    }
  } else if (cmd == "S") {
    // S <id> <forma> <argb> <grosor> x,y x,y (se repite con el mismo id al arrastrar)
    std::string id, kind, argb, a, b;
    int width = 6;
    if (!(in >> id >> kind >> argb >> width >> a >> b)) return;
    float ax, ay, bx, by;
    if (!ParsePoint(a, &ax, &ay) || !ParsePoint(b, &bx, &by)) return;
    Item& s = g_items[id];
    s.kind = Kind::kShape;
    s.shape = kind.empty() ? 'I' : kind[0];
    s.color = ParseColor(argb);
    s.width_permille = width;
    s.points = {Gdiplus::PointF(ax, ay), Gdiplus::PointF(bx, by)};
  } else if (cmd == "N" || cmd == "X") {
    // N <id> <argb> <numero> x,y   |   X <id> <argb> x,y <texto base64url>
    std::string id, argb, t1, t2;
    if (!(in >> id >> argb >> t1 >> t2)) return;
    const bool number = cmd == "N";
    float x, y;
    if (!ParsePoint(number ? t2 : t1, &x, &y)) return;
    Item s;
    s.kind = number ? Kind::kNumber : Kind::kText;
    s.color = ParseColor(argb);
    s.label = Utf8ToWide(number ? t1 : Base64UrlDecode(t2));
    s.hold_ms = kHoldMarkMs;
    s.points = {Gdiplus::PointF(x, y)};
    g_items[id] = s;
  } else if (cmd == "F") {
    // F x,y x,y | F -
    std::string a, b;
    in >> a >> b;
    float ax, ay, bx, by;
    if (ParsePoint(a, &ax, &ay) && ParsePoint(b, &bx, &by)) {
      g_focus = Gdiplus::RectF(std::min(ax, bx), std::min(ay, by), std::abs(bx - ax),
                               std::abs(by - ay));
      g_focus_on = true;
    } else {
      g_focus_on = false;
    }
  } else if (cmd == "L") {
    std::string tok;
    in >> tok;
    float x, y;
    if (tok == "-") {
      g_laser.visible = false;
    } else if (ParsePoint(tok, &x, &y)) {
      g_laser = {true, x, y, now};
      g_trail.push_back({now, x, y});
    }
  } else if (cmd == "R") {
    std::string v;
    in >> v;
    g_rec_on = v == "1";
    g_rec_beat = now;
  } else if (cmd == "B") {
    std::string v;
    in >> v;
    g_block_on = v == "1";
    g_block_beat = now;
  } else if (cmd == "D") {
    long l, t, w, h;
    if (in >> l >> t >> w >> h && w > 0 && h > 0) {
      const RECT r = {l, t, l + w, t + h};
      if (!EqualRect(&r, &g_target)) {
        g_target = r;
        if (g_hwnd) SetWindowPos(g_hwnd, HWND_TOPMOST, l, t, w, h, SWP_NOACTIVATE);
      }
    }
  }
}

}  // namespace

bool CopyImageFile(const std::string& utf8_path) {
  if (!StartGdiplus()) return false;
  const std::wstring path = Utf8ToWide(utf8_path);
  Gdiplus::Bitmap bmp(path.c_str());
  if (bmp.GetLastStatus() != Gdiplus::Ok) return false;
  const UINT w = bmp.GetWidth(), h = bmp.GetHeight();
  if (!w || !h) return false;
  Gdiplus::Rect rect(0, 0, static_cast<INT>(w), static_cast<INT>(h));
  Gdiplus::BitmapData data;
  if (bmp.LockBits(&rect, Gdiplus::ImageLockModeRead, PixelFormat32bppARGB, &data) !=
      Gdiplus::Ok) {
    return false;
  }
  const size_t stride = static_cast<size_t>(w) * 4;
  const size_t size = sizeof(BITMAPINFOHEADER) + stride * h;
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, size);
  bool ok = false;
  if (mem) {
    BYTE* dst = static_cast<BYTE*>(GlobalLock(mem));
    BITMAPINFOHEADER* bih = reinterpret_cast<BITMAPINFOHEADER*>(dst);
    ZeroMemory(bih, sizeof(BITMAPINFOHEADER));
    bih->biSize = sizeof(BITMAPINFOHEADER);
    bih->biWidth = static_cast<LONG>(w);
    bih->biHeight = static_cast<LONG>(h);  // de abajo arriba, lo normal en CF_DIB
    bih->biPlanes = 1;
    bih->biBitCount = 32;
    bih->biCompression = BI_RGB;
    bih->biSizeImage = static_cast<DWORD>(stride * h);
    BYTE* pixels = dst + sizeof(BITMAPINFOHEADER);
    for (UINT y = 0; y < h; ++y) {
      memcpy(pixels + (h - 1 - y) * stride, static_cast<BYTE*>(data.Scan0) + y * data.Stride,
             stride);
    }
    GlobalUnlock(mem);
    if (OpenClipboard(nullptr)) {
      EmptyClipboard();
      ok = SetClipboardData(CF_DIB, mem) != nullptr;
      CloseClipboard();
    }
    if (!ok) GlobalFree(mem);  // si lo acepta, el portapapeles es su dueño
  }
  bmp.UnlockBits(&data);
  return ok;
}

void Handle(const std::string& payload) {
  if (!EnsureWindow()) return;
  std::istringstream in(payload);
  std::string line;
  while (std::getline(in, line)) Apply(line);
  Render();
}

}  // namespace vantaris_overlay
