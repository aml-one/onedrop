#include "air_grab_plugin.h"
#include "catch_fog.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <dwmapi.h>
#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <setupapi.h>
#include <windows.h>

#include <atomic>
#include <cwctype>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "setupapi.lib")

// USB Windows Hello sticks expose RGB + IR. Prefer the RGB node.
DEFINE_GUID(kVideoCameraInterface, 0xE5323777, 0xF976, 0x4F5B, 0x9B, 0x55, 0xB9,
            0x46, 0x99, 0xC4, 0x6E, 0x44);

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Same pattern as drop_p2p: never touch Flutter sinks/results off the UI
// thread — that deadlocks the engine and Windows marks One Drop "Not
// responding".
constexpr UINT kAirGrabUiMessage = WM_APP + 82;

struct AirGrabUiWork {
  std::function<void()> fn;
};

template <typename T>
void SafeRelease(T** ptr) {
  if (ptr && *ptr) {
    (*ptr)->Release();
    *ptr = nullptr;
  }
}

std::wstring WideLower(const wchar_t* raw) {
  std::wstring out(raw ? raw : L"");
  for (wchar_t& c : out) {
    c = static_cast<wchar_t>(towlower(c));
  }
  return out;
}

bool IsInfraredCameraName(const std::wstring& lower) {
  if (lower.find(L"infrared") != std::wstring::npos) return true;
  if (lower.find(L" ir ") != std::wstring::npos) return true;
  if (lower.find(L"ir camera") != std::wstring::npos) return true;
  if (lower.find(L"ir cam") != std::wstring::npos) return true;
  return false;
}

bool PrefersRgbCameraName(const std::wstring& lower) {
  return lower.find(L"rgb") != std::wstring::npos ||
         lower.find(L"color") != std::wstring::npos;
}

struct CaptureCandidate {
  IMFActivate* activate = nullptr;
  std::wstring symlink;
  std::wstring name;
  bool infrared = false;
  bool rgb_name = false;
};

void ReleaseCandidates(std::vector<CaptureCandidate>* list) {
  if (!list) return;
  for (auto& candidate : *list) SafeRelease(&candidate.activate);
  list->clear();
}

void AddMfDevices(std::vector<CaptureCandidate>* out) {
  if (!out) return;
  IMFAttributes* attrs = nullptr;
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  if (FAILED(MFCreateAttributes(&attrs, 1))) return;
  attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                 MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  const HRESULT hr = MFEnumDeviceSources(attrs, &devices, &count);
  SafeRelease(&attrs);
  if (FAILED(hr) || !devices) {
    if (devices) CoTaskMemFree(devices);
    return;
  }
  for (UINT32 i = 0; i < count; i++) {
    CaptureCandidate candidate;
    candidate.activate = devices[i];
    devices[i] = nullptr;
    WCHAR* friendly = nullptr;
    UINT32 friendly_len = 0;
    if (SUCCEEDED(candidate.activate->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &friendly_len)) &&
        friendly) {
      candidate.name = WideLower(friendly);
      CoTaskMemFree(friendly);
    }
    WCHAR* link = nullptr;
    UINT32 link_len = 0;
    if (SUCCEEDED(candidate.activate->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link,
            &link_len)) &&
        link) {
      candidate.symlink = link;
      CoTaskMemFree(link);
    }
    candidate.infrared = IsInfraredCameraName(candidate.name);
    candidate.rgb_name = PrefersRgbCameraName(candidate.name);
    out->push_back(std::move(candidate));
  }
  CoTaskMemFree(devices);
}

void AddSetupApiDevices(std::vector<CaptureCandidate>* out) {
  if (!out) return;
  HDEVINFO info = SetupDiGetClassDevsW(&kVideoCameraInterface, nullptr, nullptr,
                                       DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
  if (info == INVALID_HANDLE_VALUE) return;
  SP_DEVICE_INTERFACE_DATA iface = {};
  iface.cbSize = sizeof(iface);
  for (DWORD index = 0;
       SetupDiEnumDeviceInterfaces(info, nullptr, &kVideoCameraInterface, index,
                                   &iface);
       index++) {
    DWORD needed = 0;
    SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &needed,
                                     nullptr);
    if (needed == 0) continue;
    std::vector<uint8_t> buf(needed);
    auto* detail =
        reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buf.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    SP_DEVINFO_DATA dev = {};
    dev.cbSize = sizeof(dev);
    if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, needed, nullptr,
                                          &dev)) {
      continue;
    }
    wchar_t name[512] = {};
    if (!SetupDiGetDeviceRegistryPropertyW(
            info, &dev, SPDRP_FRIENDLYNAME, nullptr,
            reinterpret_cast<PBYTE>(name), sizeof(name), nullptr)) {
      SetupDiGetDeviceRegistryPropertyW(
          info, &dev, SPDRP_DEVICEDESC, nullptr, reinterpret_cast<PBYTE>(name),
          sizeof(name), nullptr);
    }
    const std::wstring symlink = detail->DevicePath;
    const std::wstring lower_link = WideLower(symlink.c_str());
    const std::wstring lower_name = WideLower(name);
    bool seen = false;
    for (const auto& existing : *out) {
      if (!existing.symlink.empty() &&
          WideLower(existing.symlink.c_str()) == lower_link) {
        seen = true;
        break;
      }
    }
    if (seen) continue;
    CaptureCandidate candidate;
    candidate.symlink = symlink;
    candidate.name = lower_name;
    candidate.infrared =
        IsInfraredCameraName(lower_name) || IsInfraredCameraName(lower_link);
    candidate.rgb_name = PrefersRgbCameraName(lower_name);
    out->push_back(std::move(candidate));
  }
  SetupDiDestroyDeviceInfoList(info);
}

CaptureCandidate* PickRgbCamera(std::vector<CaptureCandidate>* list) {
  if (!list) return nullptr;
  CaptureCandidate* rgb = nullptr;
  CaptureCandidate* any = nullptr;
  for (auto& candidate : *list) {
    if (candidate.infrared) continue;
    if (!any) any = &candidate;
    if (candidate.rgb_name) {
      rgb = &candidate;
      break;
    }
  }
  return rgb ? rgb : any;
}

IMFMediaSource* OpenCaptureSource(CaptureCandidate* candidate) {
  if (!candidate) return nullptr;
  IMFMediaSource* source = nullptr;
  if (candidate->activate) {
    candidate->activate->ActivateObject(IID_PPV_ARGS(&source));
    if (source) return source;
  }
  if (candidate->symlink.empty()) return nullptr;
  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 2))) return nullptr;
  attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                 MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  attrs->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                   candidate->symlink.c_str());
  MFCreateDeviceSource(attrs, &source);
  SafeRelease(&attrs);
  return source;
}

EncodableMap ClassifyNone() {
  return EncodableMap{
      {EncodableValue("shape"), EncodableValue("none")},
      {EncodableValue("inFrame"), EncodableValue(false)},
      {EncodableValue("gaze"), EncodableValue(true)},
      {EncodableValue("face"), EncodableValue(false)},
      {EncodableValue("looking"), EncodableValue(false)},
      {EncodableValue("attention"), EncodableValue(0.0)},
      {EncodableValue("yaw"), EncodableValue(0.0)},
      {EncodableValue("pitch"), EncodableValue(0.0)},
  };
}

bool IsSkin(int r, int g, int b) {
  const int luma = (299 * r + 587 * g + 114 * b + 500) / 1000;
  const int cb = 128 + (-169 * r - 331 * g + 500 * b + 500) / 1000;
  const int cr = 128 + (500 * r - 419 * g - 81 * b + 500) / 1000;
  return luma >= 50 && luma <= 245 && cr >= 133 && cr <= 173 &&
         cb >= 77 && cb <= 127;
}

EncodableMap ClassifyRgb32(const uint8_t* data, int width, int height,
                           int stride) {
  // Stride may be negative (bottom-up RGB32). `data` must be the top scanline.
  if (!data || width < 16 || height < 16 || stride == 0) return ClassifyNone();
  const int abs_stride = stride < 0 ? -stride : stride;
  if (abs_stride < width * 4) return ClassifyNone();
  const int step_x = (std::max)(width / 80, 2);
  const int step_y = (std::max)(height / 60, 2);
  const int face_bottom = height * 55 / 100;

  int face_skin = 0;
  int face_min_x = width;
  int face_min_y = height;
  int face_max_x = 0;
  int face_max_y = 0;
  int all_skin = 0;
  int total = 0;

  for (int y = 0; y < height; y += step_y) {
    const uint8_t* row =
        data + static_cast<ptrdiff_t>(y) * static_cast<ptrdiff_t>(stride);
    for (int x = 0; x < width; x += step_x) {
      total++;
      const uint8_t* px = row + x * 4;
      if (!IsSkin(px[2], px[1], px[0])) continue;
      all_skin++;
      if (y > face_bottom) continue;
      face_skin++;
      if (x < face_min_x) face_min_x = x;
      if (y < face_min_y) face_min_y = y;
      if (x > face_max_x) face_max_x = x;
      if (y > face_max_y) face_max_y = y;
    }
  }

  bool face = false;
  double attention = 0.0;
  double yaw = 0.0;
  double pitch = 0.0;
  int face_x0 = 0;
  int face_y0 = 0;
  int face_x1 = 0;
  int face_y1 = 0;
  if (total > 0 && face_skin >= 8) {
    const int bw = (std::max)(face_max_x - face_min_x, 1);
    const int bh = (std::max)(face_max_y - face_min_y, 1);
    const double aspect = static_cast<double>(bw) / bh;
    const double cx = (face_min_x + face_max_x) * 0.5 / width;
    const double cy = (face_min_y + face_max_y) * 0.5 / height;
    const double area = static_cast<double>(face_skin) / total;
    if (aspect >= 0.55 && aspect <= 1.45 && cx >= 0.12 && cx <= 0.88 &&
        cy <= 0.52 && area >= 0.012 && area <= 0.42) {
      face = true;
      face_x0 = face_min_x - bw / 8;
      face_y0 = face_min_y - bh / 8;
      face_x1 = face_max_x + bw / 8;
      face_y1 = face_max_y + bh / 8;
      yaw = (cx - 0.5) * 1.6;
      pitch = (0.32 - cy) * 1.4;
      const double center = 1.0 - (std::min)(1.0, std::abs(cx - 0.5) * 2.2);
      const double size = (std::min)(1.0, area / 0.08);
      attention = center * size;
      if (attention < 0) attention = 0;
      if (attention > 1) attention = 1;
    }
  }

  int hand_skin = 0;
  int hand_min_x = width;
  int hand_min_y = height;
  int hand_max_x = 0;
  int hand_max_y = 0;
  if (all_skin >= 6) {
    for (int y = 0; y < height; y += step_y) {
      const uint8_t* row =
          data + static_cast<ptrdiff_t>(y) * static_cast<ptrdiff_t>(stride);
      for (int x = 0; x < width; x += step_x) {
        const uint8_t* px = row + x * 4;
        if (!IsSkin(px[2], px[1], px[0])) continue;
        if (face && x >= face_x0 && x <= face_x1 && y >= face_y0 &&
            y <= face_y1) {
          continue;
        }
        hand_skin++;
        if (x < hand_min_x) hand_min_x = x;
        if (y < hand_min_y) hand_min_y = y;
        if (x > hand_max_x) hand_max_x = x;
        if (y > hand_max_y) hand_max_y = y;
      }
    }
  }

  std::string shape = "none";
  bool hand_in = false;
  if (hand_skin >= 6) {
    const int bw = (std::max)(hand_max_x - hand_min_x, 1);
    const int bh = (std::max)(hand_max_y - hand_min_y, 1);
    const int box = (bw / step_x) * (bh / step_y);
    const double solidity =
        box <= 0 ? 0.0 : static_cast<double>(hand_skin) / box;
    const double aspect = static_cast<double>(bw) / bh;
    hand_in = solidity > 0.28;
    if (solidity >= 0.62 && aspect >= 0.55 && aspect <= 1.45) {
      shape = "fist";
      hand_in = true;
    } else if (solidity <= 0.52 && bh > bw * 0.85) {
      shape = "palm";
      hand_in = true;
    }
  }

  const bool looking = face && attention >= 0.38;
  return EncodableMap{
      {EncodableValue("shape"), EncodableValue(shape)},
      {EncodableValue("inFrame"), EncodableValue(hand_in)},
      {EncodableValue("gaze"), EncodableValue(true)},
      {EncodableValue("face"), EncodableValue(face)},
      {EncodableValue("looking"), EncodableValue(looking)},
      {EncodableValue("attention"), EncodableValue(attention)},
      {EncodableValue("yaw"), EncodableValue(yaw)},
      {EncodableValue("pitch"), EncodableValue(pitch)},
  };
}

// Must match PanelWindow.beaconPunch (0xFF010001).
constexpr COLORREF kBeaconPunch = RGB(1, 0, 1);

void ApplyTransparentHitTest(HWND hwnd, bool ignore) {
  if (!hwnd || !IsWindow(hwnd)) return;
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if (ignore) {
    ex |= WS_EX_TRANSPARENT;
  } else {
    ex &= ~WS_EX_TRANSPARENT;
  }
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
  for (HWND child = GetWindow(hwnd, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) {
    ApplyTransparentHitTest(child, ignore);
  }
}

void ApplyBeaconPunch(HWND hwnd, bool enable) {
  if (!hwnd || !IsWindow(hwnd)) return;
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if (enable) {
    ex |= WS_EX_LAYERED | WS_EX_TRANSPARENT;
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
    SetLayeredWindowAttributes(hwnd, kBeaconPunch, 255, LWA_COLORKEY);
  } else {
    ex &= ~(WS_EX_LAYERED | WS_EX_TRANSPARENT);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
  }
  for (HWND child = GetWindow(hwnd, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) {
    ApplyBeaconPunch(child, enable);
  }
}

class AirGrabPlugin {
 public:
  explicit AirGrabPlugin(flutter::BinaryMessenger* messenger, HWND host_window)
      : host_window_(host_window) {
    auto methods = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "one.aml.onedrop/air_grab",
        &flutter::StandardMethodCodec::GetInstance());
    methods->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
          Handle(call, std::move(result));
        });
    methods_ = std::move(methods);

    auto events = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "one.aml.onedrop/air_grab/frames",
        &flutter::StandardMethodCodec::GetInstance());
    auto handler =
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              std::lock_guard<std::mutex> lock(mutex_);
              sink_ = std::move(events);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              std::lock_guard<std::mutex> lock(mutex_);
              sink_.reset();
              return nullptr;
            });
    events->SetStreamHandler(std::move(handler));
    events_ = std::move(events);
  }

  ~AirGrabPlugin() {
    CatchFogHide();
    Stop();
    // Drop coalesced UI posts that still capture `this`.
    if (host_window_ && IsWindow(host_window_)) {
      MSG msg;
      while (PeekMessage(&msg, host_window_, kAirGrabUiMessage, kAirGrabUiMessage,
                         PM_REMOVE)) {
        delete reinterpret_cast<AirGrabUiWork*>(msg.lParam);
      }
    }
  }

  bool HandleMessage(UINT message, LPARAM lparam) {
    if (message != kAirGrabUiMessage) return false;
    auto* work = reinterpret_cast<AirGrabUiWork*>(lparam);
    if (work) {
      try {
        work->fn();
      } catch (...) {
      }
      delete work;
    }
    return true;
  }

 private:
  void PostUi(std::function<void()> fn) {
    if (!host_window_ || !IsWindow(host_window_)) {
      try {
        fn();
      } catch (...) {
      }
      return;
    }
    PostMessage(host_window_, kAirGrabUiMessage, 0,
                reinterpret_cast<LPARAM>(new AirGrabUiWork{std::move(fn)}));
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "hasCamera") {
      auto shared =
          std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
      std::thread([this, shared]() {
        const bool ok = HasCamera();
        PostUi([shared, ok]() { shared->Success(EncodableValue(ok)); });
      }).detach();
      return;
    }
    if (call.method_name() == "start") {
      auto shared =
          std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
      std::thread([this, shared]() {
        const bool ok = Start();
        PostUi([shared, ok]() { shared->Success(EncodableValue(ok)); });
      }).detach();
      return;
    }
    if (call.method_name() == "stop") {
      auto shared =
          std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
      std::thread([this, shared]() {
        Stop();
        PostUi([shared]() { shared->Success(EncodableValue(true)); });
      }).detach();
      return;
    }
    if (call.method_name() == "showCatchFog") {
      CatchFogShow(ParseLocked(call));
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "hideCatchFog") {
      CatchFogHide();
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "setClickThrough") {
      SetClickThrough(ParseIgnore(call));
      result->Success(EncodableValue(true));
      return;
    }
    result->NotImplemented();
  }

  static bool ParseIgnore(const flutter::MethodCall<EncodableValue>& call) {
    const EncodableValue* arguments = call.arguments();
    if (!arguments) return false;
    const auto* map = std::get_if<EncodableMap>(arguments);
    if (!map) return false;
    auto it = map->find(EncodableValue("ignore"));
    if (it == map->end()) return false;
    if (const auto* flag = std::get_if<bool>(&it->second)) return *flag;
    return false;
  }

  static bool ParseLocked(const flutter::MethodCall<EncodableValue>& call) {
    const EncodableValue* arguments = call.arguments();
    if (!arguments) return false;
    const auto* map = std::get_if<EncodableMap>(arguments);
    if (!map) return false;
    auto it = map->find(EncodableValue("locked"));
    if (it == map->end()) return false;
    if (const auto* flag = std::get_if<bool>(&it->second)) return *flag;
    return false;
  }

  void SetClickThrough(bool ignore) {
    HWND hwnd = host_window_;
    if (!hwnd || !IsWindow(hwnd)) return;
    ApplyTransparentHitTest(hwnd, ignore);
    if (ignore) {
      // Punch the magenta fill behind the fog. Do not key black/clear —
      // Flutter paints those as an opaque white plate. Do not use
      // window_manager's setIgnoreMouseEvents: it ORs WS_EX_LAYERED
      // without a color key.
      ApplyBeaconPunch(hwnd, true);
      const MARGINS margins = {-1, -1, -1, -1};
      DwmExtendFrameIntoClientArea(hwnd, &margins);
    } else {
      ApplyBeaconPunch(hwnd, false);
      const MARGINS margins = {0, 0, 0, 0};
      DwmExtendFrameIntoClientArea(hwnd, &margins);
    }
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    InvalidateRect(hwnd, nullptr, TRUE);
  }

  bool HasCamera() {
    std::vector<CaptureCandidate> devices;
    AddMfDevices(&devices);
    AddSetupApiDevices(&devices);
    const bool found = PickRgbCamera(&devices) != nullptr;
    ReleaseCandidates(&devices);
    return found;
  }

  bool ConfigureSmallRgb32(IMFSourceReader* reader) {
    if (!reader) return false;
    // Prefer tiny frames so classify stays cheap. Fall back to any RGB32.
    static const UINT32 kSizes[][2] = {{320, 240}, {640, 480}, {0, 0}};
    for (const auto& size : kSizes) {
      IMFMediaType* type = nullptr;
      if (FAILED(MFCreateMediaType(&type)) || !type) return false;
      type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      if (size[0] > 0) {
        MFSetAttributeSize(type, MF_MT_FRAME_SIZE, size[0], size[1]);
        MFSetAttributeRatio(type, MF_MT_FRAME_RATE, 5, 1);
      }
      const HRESULT hr = reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
          type);
      SafeRelease(&type);
      if (SUCCEEDED(hr)) return true;
    }
    return false;
  }

  bool Start() {
    if (running_.load() && reader_ != nullptr) return true;
    Stop();
    std::vector<CaptureCandidate> devices;
    AddMfDevices(&devices);
    AddSetupApiDevices(&devices);
    CaptureCandidate* pick = PickRgbCamera(&devices);
    IMFMediaSource* source = OpenCaptureSource(pick);
    ReleaseCandidates(&devices);
    if (!source) return false;
    IMFSourceReader* reader = nullptr;
    HRESULT hr = S_OK;

    IMFAttributes* reader_attrs = nullptr;
    MFCreateAttributes(&reader_attrs, 1);
    if (reader_attrs) {
      reader_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    }
    hr = MFCreateSourceReaderFromMediaSource(source, reader_attrs, &reader);
    SafeRelease(&reader_attrs);
    SafeRelease(&source);
    if (FAILED(hr) || !reader) return false;

    if (!ConfigureSmallRgb32(reader)) {
      // Without an RGB32 output type ClassifyRgb32 would walk the wrong
      // layout and AV. Fail start instead of crashing mid-frame.
      SafeRelease(&reader);
      return false;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      reader_ = reader;
    }
    running_.store(true);
    worker_ = std::thread([this]() { Loop(); });
    return true;
  }

  void Stop() {
    running_.store(false);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (reader_) {
        reader_->Flush(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS));
      }
    }
    if (worker_.joinable()) worker_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    SafeRelease(&reader_);
  }

  void Loop() {
    int skip = 0;
    DWORD last_emit_ms = 0;
    while (running_.load()) {
      IMFSourceReader* reader = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        reader = reader_;
        if (reader) reader->AddRef();
      }
      if (!reader) break;
      DWORD stream = 0;
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      IMFSample* sample = nullptr;
      HRESULT hr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &stream,
          &flags, &timestamp, &sample);
      SafeRelease(&reader);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
        SafeRelease(&sample);
        break;
      }
      skip++;
      // Hard pacing: never spin the MF graph at full camera FPS. That busy
      // loop (plus RGB classify) is what froze the desktop before.
      const DWORD now = GetTickCount();
      const bool due = (now - last_emit_ms) >= 200;  // ≤5 Hz classify/emit
      if (skip % 4 != 0 || !sample || !due) {
        SafeRelease(&sample);
        Sleep(40);
        continue;
      }
      IMFMediaBuffer* buffer = nullptr;
      if (FAILED(sample->ConvertToContiguousBuffer(&buffer)) || !buffer) {
        SafeRelease(&sample);
        continue;
      }

      IMFMediaType* current = nullptr;
      UINT32 width = 0;
      UINT32 height = 0;
      LONG stride = 0;
      GUID subtype = GUID_NULL;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (reader_) {
          reader_->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &current);
        }
      }
      if (current) {
        MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &width, &height);
        current->GetGUID(MF_MT_SUBTYPE, &subtype);
        UINT32 stride_u = 0;
        if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u))) {
          stride = static_cast<LONG>(stride_u);
        }
        SafeRelease(&current);
      }
      if (subtype != MFVideoFormat_RGB32 || width < 16 || height < 16) {
        SafeRelease(&buffer);
        SafeRelease(&sample);
        continue;
      }
      if (stride == 0) stride = static_cast<LONG>(width) * 4;

      EncodableMap event = ClassifyNone();
      bool classified = false;

      IMF2DBuffer* buffer2d = nullptr;
      if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d))) &&
          buffer2d) {
        BYTE* scan0 = nullptr;
        LONG pitch = 0;
        if (SUCCEEDED(buffer2d->Lock2D(&scan0, &pitch)) && scan0 && pitch != 0) {
          event = ClassifyRgb32(scan0, static_cast<int>(width),
                                static_cast<int>(height),
                                static_cast<int>(pitch));
          classified = true;
          buffer2d->Unlock2D();
        }
        SafeRelease(&buffer2d);
      }

      if (!classified) {
        BYTE* data = nullptr;
        DWORD max_len = 0;
        DWORD cur_len = 0;
        if (SUCCEEDED(buffer->Lock(&data, &max_len, &cur_len)) && data) {
          const LONG abs_stride = stride < 0 ? -stride : stride;
          const uint64_t need =
              static_cast<uint64_t>(abs_stride) * static_cast<uint64_t>(height);
          if (cur_len >= need && max_len >= need) {
            // Contiguous Lock on bottom-up RGB32: `data` is the first byte of
            // the buffer (bottom row). Re-base to the top scanline so negative
            // stride walks back through valid memory.
            const uint8_t* top = data;
            if (stride < 0 && height > 0) {
              top = data + static_cast<size_t>(height - 1) *
                               static_cast<size_t>(abs_stride);
            }
            event = ClassifyRgb32(top, static_cast<int>(width),
                                  static_cast<int>(height),
                                  static_cast<int>(stride));
            classified = true;
          }
          buffer->Unlock();
        }
      }

      if (classified) {
        last_emit_ms = now;
        Emit(event);
      }
      SafeRelease(&buffer);
      SafeRelease(&sample);
      // Pace the worker even after a classify so we never peg a core.
      Sleep(120);
    }
    running_.store(false);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      SafeRelease(&reader_);
    }
    Emit(ClassifyNone());
  }

  void Emit(EncodableMap event) {
    bool post = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending_ = std::move(event);
      has_pending_ = true;
      if (!emit_posted_) {
        emit_posted_ = true;
        post = true;
      }
    }
    if (post) {
      PostUi([this]() { FlushPendingEmit(); });
    }
  }

  void FlushPendingEmit() {
    std::lock_guard<std::mutex> lock(mutex_);
    emit_posted_ = false;
    if (!has_pending_ || !sink_) return;
    has_pending_ = false;
    sink_->Success(EncodableValue(pending_));
  }

  HWND host_window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::mutex mutex_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
  EncodableMap pending_;
  bool has_pending_ = false;
  bool emit_posted_ = false;
  IMFSourceReader* reader_ = nullptr;
  std::atomic<bool> running_{false};
  std::thread worker_;
};

AirGrabPlugin* g_plugin = nullptr;

}  // namespace

void RegisterAirGrabPlugin(flutter::BinaryMessenger* messenger,
                           HWND host_window) {
  static bool mf_started = false;
  if (!mf_started) {
    MFStartup(MF_VERSION);
    mf_started = true;
  }
  AirGrabPlugin* old = g_plugin;
  g_plugin = nullptr;
  delete old;
  g_plugin = new AirGrabPlugin(messenger, host_window);
}

bool AirGrabHandleMessage(HWND /*hwnd*/, UINT message, WPARAM /*wparam*/,
                          LPARAM lparam) {
  if (!g_plugin) return false;
  return g_plugin->HandleMessage(message, lparam);
}
