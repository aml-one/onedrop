#include "catch_fog.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace {

constexpr wchar_t kClass[] = L"OneDropCatchFog";
constexpr UINT kTimerId = 1;
// 10 fps is enough for a soft breath; 30 fps CPU-composited blobs were
// part of the desktop freeze reports.
constexpr UINT kTimerMs = 150;
constexpr float kPeriodMs = 1600.f;

HWND g_hwnd = nullptr;
HBITMAP g_dib = nullptr;
void* g_bits = nullptr;
int g_width = 0;
int g_height = 0;
int g_x = 0;
int g_y = 0;
DWORD g_start = 0;
bool g_locked = false;

struct Color {
  float r;
  float g;
  float b;
};

void BlendPremul(uint8_t* px, float sr, float sg, float sb, float sa) {
  if (sa <= 0.f) return;
  if (sa > 1.f) sa = 1.f;
  // Buffer is premultiplied BGRA for UpdateLayeredWindow(ULW_ALPHA).
  const float da = px[3] / 255.f;
  const float dr = px[2] / 255.f;
  const float dg = px[1] / 255.f;
  const float db = px[0] / 255.f;
  const float out_a = sa + da * (1.f - sa);
  const float out_r = sr * sa + dr * (1.f - sa);
  const float out_g = sg * sa + dg * (1.f - sa);
  const float out_b = sb * sa + db * (1.f - sa);
  px[0] = static_cast<uint8_t>(out_b * 255.f + 0.5f);
  px[1] = static_cast<uint8_t>(out_g * 255.f + 0.5f);
  px[2] = static_cast<uint8_t>(out_r * 255.f + 0.5f);
  px[3] = static_cast<uint8_t>(out_a * 255.f + 0.5f);
}

float Falloff(float t, float inner, float mid) {
  if (t <= 0.f) return inner;
  if (t >= 1.f) return 0.f;
  if (t <= 0.40f) {
    const float u = t / 0.40f;
    return inner + (mid - inner) * u;
  }
  const float u = (t - 0.40f) / 0.60f;
  return mid * (1.f - u);
}

void Blob(uint8_t* bits, int w, int h, float cx, float cy, float radius,
          Color color, float inner, float mid) {
  if (radius < 8.f) return;
  const int x0 = (std::max)(0, static_cast<int>(cx - radius) - 1);
  const int y0 = (std::max)(0, static_cast<int>(cy - radius) - 1);
  const int x1 = (std::min)(w - 1, static_cast<int>(cx + radius) + 1);
  const int y1 = (std::min)(h - 1, static_cast<int>(cy + radius) + 1);
  const float inv = 1.f / radius;
  for (int y = y0; y <= y1; y++) {
    uint8_t* row = bits + y * w * 4;
    const float dy = y + 0.5f - cy;
    for (int x = x0; x <= x1; x++) {
      const float dx = x + 0.5f - cx;
      const float t = std::sqrt(dx * dx + dy * dy) * inv;
      if (t >= 1.f) continue;
      BlendPremul(row + x * 4, color.r, color.g, color.b,
                  Falloff(t, inner, mid));
    }
  }
}

float Breath() {
  const float elapsed = static_cast<float>(GetTickCount() - g_start);
  float phase = std::fmod(elapsed / kPeriodMs, 1.f);
  if (phase < 0.f) phase += 1.f;
  float t = phase < 0.5f ? phase * 2.f : (1.f - phase) * 2.f;
  t = t * t * (3.f - 2.f * t);
  return t;
}

void Paint() {
  if (!g_hwnd || !g_bits || g_width <= 0 || g_height <= 0) return;
  std::memset(g_bits, 0, static_cast<size_t>(g_width) * g_height * 4);
  const float breath = Breath();
  const float span = static_cast<float>((std::min)(g_width, g_height));
  const float ox = g_width * 0.5f;
  const float oy = g_height * 0.5f;
  auto* bits = static_cast<uint8_t*>(g_bits);
  if (g_locked) {
    const float radius = span * (0.30f + breath * 0.08f);
    const float inner = 0.62f + breath * 0.14f;
    const float mid = 0.26f + breath * 0.10f;
    Blob(bits, g_width, g_height, ox - 0.04f * radius, oy - 0.03f * radius,
         radius, Color{1.f, 0.882f, 0.290f}, inner, mid);
    Blob(bits, g_width, g_height, ox + 0.10f * radius, oy + 0.06f * radius,
         radius * 0.72f, Color{0.361f, 0.796f, 0.706f}, inner * 0.55f,
         mid * 0.55f);
    Blob(bits, g_width, g_height, ox - 0.08f * radius, oy + 0.08f * radius,
         radius * 0.68f, Color{0.435f, 0.694f, 0.941f}, inner * 0.48f,
         mid * 0.48f);
  } else {
    const float radius = span * (0.42f + breath * 0.06f);
    const float inner = 0.52f + breath * 0.08f;
    const float mid = 0.18f + breath * 0.05f;
    Blob(bits, g_width, g_height, ox, oy, radius,
         Color{0.957f, 0.969f, 1.f}, inner, mid);
  }

  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HGDIOBJ old = SelectObject(mem, g_dib);
  POINT dst{g_x, g_y};
  POINT src{0, 0};
  SIZE size{g_width, g_height};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(g_hwnd, screen, &dst, &size, mem, &src, 0, &blend,
                      ULW_ALPHA);
  SelectObject(mem, old);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
}

void DestroySurface() {
  if (g_dib) {
    DeleteObject(g_dib);
    g_dib = nullptr;
  }
  g_bits = nullptr;
}

bool MakeSurface(int width, int height) {
  DestroySurface();
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  g_dib = CreateDIBSection(nullptr, &bmi, DIB_RGB_COLORS, &g_bits, nullptr, 0);
  if (!g_dib || !g_bits) {
    DestroySurface();
    return false;
  }
  g_width = width;
  g_height = height;
  return true;
}

void Place(bool locked) {
  HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  GetMonitorInfo(monitor, &info);
  const RECT work = info.rcWork;
  const int work_w = work.right - work.left;
  const int work_h = work.bottom - work.top;
  const int shortest = (std::min)(work_w, work_h);
  int side;
  if (locked) {
    side = static_cast<int>(shortest * 0.36);
    if (side < 200) side = 200;
    if (side > 320) side = 320;
  } else {
    side = static_cast<int>(shortest * 0.12);
    if (side < 96) side = 96;
    if (side > 160) side = 160;
  }
  g_width = side;
  g_height = side;
  g_x = work.left + (work_w - side) / 2;
  g_y = work.top + (work_h - side) / 2;
}

LRESULT CALLBACK FogProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_TIMER && wparam == kTimerId) {
    Paint();
    return 0;
  }
  if (msg == WM_NCHITTEST) {
    return HTTRANSPARENT;
  }
  if (msg == WM_DESTROY) {
    if (g_hwnd == hwnd) g_hwnd = nullptr;
    return 0;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

void RegisterClassOnce() {
  static bool ready = false;
  if (ready) return;
  WNDCLASS wc{};
  wc.lpfnWndProc = FogProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClass(&wc);
  ready = true;
}

}  // namespace

void CatchFogHide() {
  if (g_hwnd && IsWindow(g_hwnd)) {
    KillTimer(g_hwnd, kTimerId);
    DestroyWindow(g_hwnd);
  }
  g_hwnd = nullptr;
  g_locked = false;
  DestroySurface();
}

void CatchFogShow(bool locked) {
  RegisterClassOnce();
  const bool resize = g_hwnd == nullptr || !IsWindow(g_hwnd) || g_locked != locked;
  g_locked = locked;
  Place(locked);
  if (resize && !MakeSurface(g_width, g_height)) return;
  if (!g_hwnd || !IsWindow(g_hwnd)) {
    g_hwnd = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
            WS_EX_NOACTIVATE,
        kClass, L"", WS_POPUP, g_x, g_y, g_width, g_height, nullptr, nullptr,
        GetModuleHandle(nullptr), nullptr);
    if (!g_hwnd) {
      DestroySurface();
      return;
    }
  } else {
    SetWindowPos(g_hwnd, HWND_TOPMOST, g_x, g_y, g_width, g_height,
                 SWP_NOACTIVATE);
  }
  g_start = GetTickCount();
  Paint();
  ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
  SetTimer(g_hwnd, kTimerId, kTimerMs, nullptr);
}
