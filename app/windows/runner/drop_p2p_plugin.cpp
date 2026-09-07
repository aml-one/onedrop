#include "drop_p2p_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <combaseapi.h>
#include <wlanapi.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "wlanapi.lib")
#pragma comment(lib, "windowsapp.lib")

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace wble = winrt::Windows::Devices::Bluetooth;
namespace wadv = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace wgatt = winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
namespace wfd = winrt::Windows::Devices::WiFiDirect;
namespace wss = winrt::Windows::Storage::Streams;
namespace wnet = winrt::Windows::Networking;
namespace wnc = winrt::Windows::Networking::Connectivity;
namespace wsec = winrt::Windows::Security::Credentials;

constexpr UINT kDropP2pMessage = WM_APP + 81;
constexpr uint16_t kCompany = 0x0A11;
constexpr uint16_t kCompanyName = 0x0A12;

winrt::guid GuidFrom(const wchar_t* text) {
  winrt::guid value{};
  CLSIDFromString(text, reinterpret_cast<CLSID*>(&value));
  return value;
}

const winrt::guid kServiceUuid =
    GuidFrom(L"{a11d0d01-6d65-4f6e-6472-6f70426c6531}");
const winrt::guid kInfoUuid =
    GuidFrom(L"{a11d0d01-6d65-4f6e-6472-6f70426c6532}");
const winrt::guid kLinkUuid =
    GuidFrom(L"{a11d0d01-6d65-4f6e-6472-6f70426c6533}");

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0,
                                    nullptr, nullptr);
  std::string out(n > 0 ? n - 1 : 0, '\0');
  if (n > 1) {
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), n, nullptr,
                        nullptr);
  }
  return out;
}

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  std::wstring out(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) {
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), n);
  }
  return out;
}

std::string BytesToString(const uint8_t* data, size_t n) {
  return std::string(reinterpret_cast<const char*>(data),
                     reinterpret_cast<const char*>(data) + n);
}

std::vector<uint8_t> BufferBytes(wss::IBuffer const& buffer) {
  auto reader = wss::DataReader::FromBuffer(buffer);
  std::vector<uint8_t> bytes(buffer.Length());
  if (!bytes.empty()) reader.ReadBytes(bytes);
  return bytes;
}

wss::IBuffer BytesToBuffer(const std::string& text) {
  wss::DataWriter writer;
  std::vector<uint8_t> bytes(text.begin(), text.end());
  writer.WriteBytes(bytes);
  return writer.DetachBuffer();
}

std::string JsonGet(const std::string& json, const char* key) {
  const std::string needle = std::string("\"") + key + "\":";
  auto pos = json.find(needle);
  if (pos == std::string::npos) return {};
  pos += needle.size();
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\"')) {
    if (json[pos] == '\"') {
      auto end = json.find('\"', pos + 1);
      if (end == std::string::npos) return {};
      return json.substr(pos + 1, end - pos - 1);
    }
    pos++;
  }
  auto end = json.find_first_of(",}", pos);
  if (end == std::string::npos) return json.substr(pos);
  return json.substr(pos, end - pos);
}

std::string RandomPsk() {
  static const char kChars[] = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  std::string out(12, 'a');
  uint32_t seed = GetTickCount() ^ GetCurrentProcessId();
  for (int i = 0; i < 12; i++) {
    seed = seed * 1664525u + 1013904223u;
    out[i] = kChars[seed % (sizeof(kChars) - 1)];
  }
  return out;
}

std::string HotspotIp() {
  try {
    std::string fallback;
    for (auto const& name : wnc::NetworkInformation::GetHostNames()) {
      if (name.Type() != wnet::HostNameType::Ipv4) continue;
      const auto ip = Narrow(std::wstring(name.CanonicalName()));
      if (ip.rfind("192.168.173.", 0) == 0 ||
          ip.rfind("192.168.137.", 0) == 0 ||
          ip.rfind("192.168.49.", 0) == 0) {
        return ip;
      }
      if (fallback.empty() && ip.rfind("192.168.", 0) == 0) fallback = ip;
    }
    if (!fallback.empty()) return fallback;
  } catch (...) {
  }
  return "192.168.173.1";
}

struct PostedWork {
  std::function<void()> fn;
};

class DropP2pPlugin {
 public:
  DropP2pPlugin(flutter::BinaryMessenger* messenger, HWND host)
      : host_(host) {
    methods_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "one.aml.onedrop/p2p",
        &flutter::StandardMethodCodec::GetInstance());
    methods_->SetMethodCallHandler(
        [this](const auto& call, auto result) { OnMethod(call, std::move(result)); });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "one.aml.onedrop/p2p-peers",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              std::lock_guard<std::mutex> lock(mutex_);
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              std::lock_guard<std::mutex> lock(mutex_);
              sink_.reset();
              return nullptr;
            }));
    worker_ = std::thread([this] {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      while (true) {
        std::function<void()> job;
        {
          std::unique_lock<std::mutex> lock(work_mutex_);
          work_cv_.wait(lock, [&] { return stop_worker_ || !work_.empty(); });
          if (stop_worker_ && work_.empty()) break;
          job = std::move(work_.front());
          work_.pop();
        }
        try {
          job();
        } catch (...) {
        }
      }
    });
  }

  ~DropP2pPlugin() {
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      stop_worker_ = true;
    }
    work_cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    StopAll();
  }

  bool HandleMessage(UINT message, LPARAM lparam) {
    if (message != kDropP2pMessage) return false;
    auto* work = reinterpret_cast<PostedWork*>(lparam);
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
  using MethodResult =
      std::unique_ptr<flutter::MethodResult<EncodableValue>>;

  void PostUi(std::function<void()> fn) {
    PostMessage(host_, kDropP2pMessage, 0,
                reinterpret_cast<LPARAM>(new PostedWork{std::move(fn)}));
  }

  void RunOnWorker(std::function<void()> fn) {
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      work_.push(std::move(fn));
    }
    work_cv_.notify_one();
  }

  void OnMethod(const flutter::MethodCall<EncodableValue>& call,
                MethodResult result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (call.method_name() == "start") {
      if (args) {
        peer_id_ = StringArg(*args, "peerId");
        name_ = StringArg(*args, "name");
        http_port_ = IntArg(*args, "port");
        beacon_ = BytesArg(*args, "beacon");
        name_bytes_ = BytesArg(*args, "nameBytes");
      }
      RunOnWorker([this] { StartRadio(); });
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "stop") {
      RunOnWorker([this] { StopAll(); });
      result->Success(EncodableValue(true));
      return;
    }
    if (call.method_name() == "connect") {
      const std::string id = args ? StringArg(*args, "peerId") : "";
      RunOnWorker([this, id, res = result.release()]() mutable {
        Connect(id, MethodResult(res));
      });
      return;
    }
    if (call.method_name() == "teardown") {
      RunOnWorker([this] { TeardownClient(); });
      result->Success(EncodableValue(true));
      return;
    }
    result->NotImplemented();
  }

  static std::string StringArg(const EncodableMap& args, const char* key) {
    auto it = args.find(EncodableValue(key));
    if (it == args.end()) return {};
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
    return {};
  }

  static int IntArg(const EncodableMap& args, const char* key) {
    auto it = args.find(EncodableValue(key));
    if (it == args.end()) return 0;
    if (const auto* n = std::get_if<int32_t>(&it->second)) return *n;
    if (const auto* n = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*n);
    }
    return 0;
  }

  static std::vector<uint8_t> BytesArg(const EncodableMap& args,
                                       const char* key) {
    auto it = args.find(EncodableValue(key));
    if (it == args.end()) return {};
    if (const auto* b = std::get_if<std::vector<uint8_t>>(&it->second)) {
      return *b;
    }
    return {};
  }

  void StartRadio() {
    StartGattServer();
    StartAdvertise();
    StartWatch();
  }

  void StartAdvertise() {
    try {
      publisher_ = wadv::BluetoothLEAdvertisementPublisher();
      wadv::BluetoothLEManufacturerData data;
      data.CompanyId(kCompany);
      data.Data(BytesToBuffer(BytesToString(beacon_.data(), beacon_.size())));
      publisher_.Advertisement().ManufacturerData().Append(data);
      if (!name_.empty()) {
        try {
          publisher_.Advertisement().LocalName(Widen(name_.substr(0, 8)));
        } catch (...) {
        }
      }
      publisher_.Start();
    } catch (...) {
    }
  }

  void StartWatch() {
    try {
      watcher_ = wadv::BluetoothLEAdvertisementWatcher();
      watcher_.ScanningMode(wadv::BluetoothLEScanningMode::Active);
      watcher_.Received(
          [this](auto&&, wadv::BluetoothLEAdvertisementReceivedEventArgs const&
                             args) { OnAdvertisement(args); });
      watcher_.Start();
    } catch (...) {
    }
  }

  void OnAdvertisement(
      wadv::BluetoothLEAdvertisementReceivedEventArgs const& args) {
    std::vector<uint8_t> beacon;
    std::vector<uint8_t> name;
    for (auto const& row : args.Advertisement().ManufacturerData()) {
      auto bytes = BufferBytes(row.Data());
      if (row.CompanyId() == kCompany) beacon = std::move(bytes);
      if (row.CompanyId() == kCompanyName) name = std::move(bytes);
    }
    if (beacon.size() < 22) return;
    if (beacon[0] != 0x4F || beacon[1] != 0x44 || beacon[2] != 1) return;
    const int port = (beacon[4] << 8) | beacon[5];
    if (port <= 0) return;
    int end = 22;
    while (end > 6 && beacon[end - 1] == 0) end--;
    std::string id = BytesToString(beacon.data() + 6, end - 6);
    while (!id.empty() && id.back() == '\0') id.pop_back();
    if (id.empty() || id == peer_id_) return;
    const int flags = beacon[3];
    const std::string role = (flags & 0x03) == 1 ? "desktop" : "phone";
    std::string os = "other";
    switch ((flags >> 2) & 0x07) {
      case 1:
        os = "android";
        break;
      case 2:
        os = "windows";
        break;
      case 3:
        os = "linux";
        break;
      case 4:
        os = "macos";
        break;
    }
    std::string display = name.empty() ? "One Drop" : BytesToString(name.data(), name.size());
    if (display.empty() || display == "One Drop") {
      const auto local = Narrow(std::wstring(args.Advertisement().LocalName()));
      if (!local.empty()) display = local;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      addresses_[id] = args.BluetoothAddress();
    }
    PostUi([this, id, display, port, role, os] {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!sink_) return;
      sink_->Success(EncodableValue(EncodableMap{
          {EncodableValue("peerId"), EncodableValue(id)},
          {EncodableValue("name"), EncodableValue(display)},
          {EncodableValue("port"), EncodableValue(port)},
          {EncodableValue("role"), EncodableValue(role)},
          {EncodableValue("os"), EncodableValue(os)},
      }));
    });
  }

  void StartGattServer() {
    try {
      auto created = wgatt::GattServiceProvider::CreateAsync(kServiceUuid).get();
      if (created.Error() != wble::BluetoothError::Success) return;
      provider_ = created.ServiceProvider();
      auto service = provider_.Service();
      wgatt::GattLocalCharacteristicParameters info_params;
      info_params.CharacteristicProperties(wgatt::GattCharacteristicProperties::Read);
      info_params.ReadProtectionLevel(wgatt::GattProtectionLevel::Plain);
      auto info_created =
          service.CreateCharacteristicAsync(kInfoUuid, info_params).get();
      info_ = info_created.Characteristic();
      info_.ReadRequested(
          [this](auto&&, wgatt::GattReadRequestedEventArgs const& args) {
            auto deferral = args.GetDeferral();
            args.GetRequestAsync().Completed(
                [this, deferral](auto&& op, auto status) {
                  if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
                    auto request = op.GetResults();
                    std::ostringstream json;
                    json << "{\"v\":1,\"peerId\":\"" << peer_id_
                         << "\",\"name\":\"" << name_ << "\",\"port\":"
                         << http_port_ << "}";
                    request.RespondWithValue(BytesToBuffer(json.str()));
                  }
                  deferral.Complete();
                });
          });
      wgatt::GattLocalCharacteristicParameters link_params;
      link_params.CharacteristicProperties(
          wgatt::GattCharacteristicProperties::Write |
          wgatt::GattCharacteristicProperties::Notify);
      link_params.WriteProtectionLevel(wgatt::GattProtectionLevel::Plain);
      auto link_created =
          service.CreateCharacteristicAsync(kLinkUuid, link_params).get();
      link_ = link_created.Characteristic();
      link_.WriteRequested(
          [this](auto&&, wgatt::GattWriteRequestedEventArgs const& args) {
            auto deferral = args.GetDeferral();
            args.GetRequestAsync().Completed(
                [this, deferral](auto&& op, auto status) {
                  if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
                    auto request = op.GetResults();
                    auto bytes = BufferBytes(request.Value());
                    const std::string json = BytesToString(bytes.data(), bytes.size());
                    request.Respond();
                    HandleLinkWrite(json);
                  }
                  deferral.Complete();
                });
          });
      wgatt::GattServiceProviderAdvertisingParameters adv;
      adv.IsConnectable(true);
      adv.IsDiscoverable(true);
      provider_.StartAdvertising(adv);
    } catch (...) {
    }
  }

  void HandleLinkWrite(const std::string& json) {
    const auto type = JsonGet(json, "t");
    if (type == "host") {
      StartAp();
    } else if (type == "done") {
      StopAp();
    }
  }

  void StartAp() {
    try {
      if (!ap_publisher_) {
        ap_publisher_ = wfd::WiFiDirectAdvertisementPublisher();
      }
      auto adv = ap_publisher_.Advertisement();
      adv.IsAutonomousGroupOwnerEnabled(true);
      auto legacy = adv.LegacySettings();
      legacy.IsEnabled(true);
      ssid_ = "OneDrop-" + (peer_id_.size() > 4 ? peer_id_.substr(peer_id_.size() - 4)
                                                : peer_id_);
      psk_ = RandomPsk();
      legacy.Ssid(Widen(ssid_));
      wsec::PasswordCredential cred;
      cred.Password(Widen(psk_));
      legacy.Passphrase(cred);
      ap_publisher_.Start();
      for (int i = 0; i < 8; i++) {
        Sleep(250);
        const auto ip = HotspotIp();
        if (ip.rfind("192.168.173.", 0) == 0 ||
            ip.rfind("192.168.137.", 0) == 0 ||
            ip.rfind("192.168.49.", 0) == 0) {
          break;
        }
      }
      NotifyAp();
    } catch (...) {
      NotifyLink("{\"t\":\"err\",\"m\":\"wifi\"}");
    }
  }

  void StopAp() {
    try {
      if (ap_publisher_) ap_publisher_.Stop();
    } catch (...) {
    }
  }

  void NotifyAp() {
    std::ostringstream json;
    json << "{\"t\":\"ap\",\"ssid\":\"" << ssid_ << "\",\"psk\":\"" << psk_
         << "\",\"ip\":\"" << HotspotIp() << "\",\"port\":" << http_port_
         << "}";
    NotifyLink(json.str());
  }

  void NotifyLink(const std::string& json) {
    try {
      if (link_) {
        link_.NotifyValueAsync(BytesToBuffer(json));
      }
    } catch (...) {
    }
  }

  void Connect(const std::string& id, MethodResult result) {
    uint64_t address = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = addresses_.find(id);
      if (it == addresses_.end()) {
        PostUi([res = result.release()]() {
          MethodResult(res)->Error("missing", "That device is no longer nearby");
        });
        return;
      }
      address = it->second;
    }
    try {
      auto device = wble::BluetoothLEDevice::FromBluetoothAddressAsync(address).get();
      if (!device) {
        PostUi([res = result.release()]() {
          MethodResult(res)->Error("link", "Bluetooth failed");
        });
        return;
      }
      auto services =
          device.GetGattServicesForUuidAsync(kServiceUuid).get();
      if (services.Services().Size() == 0) {
        PostUi([res = result.release()]() {
          MethodResult(res)->Error("link", "That device is not ready for One Drop");
        });
        return;
      }
      auto service = services.Services().GetAt(0);
      auto chars = service.GetCharacteristicsForUuidAsync(kLinkUuid).get();
      if (chars.Characteristics().Size() == 0) {
        PostUi([res = result.release()]() {
          MethodResult(res)->Error("link", "That device is not ready for One Drop");
        });
        return;
      }
      client_link_ = chars.Characteristics().GetAt(0);
      pending_connect_ = std::move(result);
      client_link_.WriteClientCharacteristicConfigurationDescriptorAsync(
          wgatt::GattClientCharacteristicConfigurationDescriptorValue::Notify)
          .get();
      client_link_.ValueChanged(
          [this](auto&&, wgatt::GattValueChangedEventArgs const& args) {
            auto bytes = BufferBytes(args.CharacteristicValue());
            const std::string json = BytesToString(bytes.data(), bytes.size());
            const auto type = JsonGet(json, "t");
            if (type == "ap") {
              JoinAp(JsonGet(json, "ssid"), JsonGet(json, "psk"),
                     JsonGet(json, "ip"), JsonGet(json, "port"));
            } else if (type == "err") {
              FailConnect("The other device could not open Wi-Fi");
            }
          });
      client_link_.WriteValueAsync(BytesToBuffer("{\"t\":\"host\"}")).get();
    } catch (...) {
      FailConnect("Could not reach them nearby");
    }
  }

  void JoinAp(const std::string& ssid, const std::string& psk,
              const std::string& ip, const std::string& port_text) {
    int port = 0;
    try {
      port = std::stoi(port_text);
    } catch (...) {
      port = http_port_;
    }
    if (ssid.empty() || psk.empty() || ip.empty() || port <= 0) {
      FailConnect("The other device could not open Wi-Fi");
      return;
    }
    if (!WlanJoin(ssid, psk)) {
      FailConnect("Could not join the private Wi-Fi");
      return;
    }
    joined_ssid_ = ssid;
    SucceedConnect(ip, port);
  }

  bool WlanJoin(const std::string& ssid, const std::string& psk) {
    HANDLE handle = nullptr;
    DWORD version = 0;
    if (WlanOpenHandle(2, nullptr, &version, &handle) != ERROR_SUCCESS) {
      return false;
    }
    PWLAN_INTERFACE_INFO_LIST list = nullptr;
    bool ok = false;
    if (WlanEnumInterfaces(handle, nullptr, &list) == ERROR_SUCCESS && list &&
        list->dwNumberOfItems > 0) {
      const GUID guid = list->InterfaceInfo[0].InterfaceGuid;
      SaveCurrent(handle, guid);
      std::ostringstream xml;
      xml << "<?xml version=\"1.0\"?>"
          << "<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/"
             "profile/v1\">"
          << "<name>" << ssid << "</name><SSIDConfig><SSID><name>" << ssid
          << "</name></SSID></SSIDConfig>"
          << "<connectionType>ESS</connectionType>"
          << "<connectionMode>manual</connectionMode><MSM><security>"
          << "<authEncryption><authentication>WPA2PSK</authentication>"
          << "<encryption>AES</encryption><useOneX>false</useOneX>"
          << "</authEncryption><sharedKey><keyType>passPhrase</keyType>"
          << "<protected>false</protected><keyMaterial>" << psk
          << "</keyMaterial></sharedKey></security></MSM></WLANProfile>";
      const std::wstring wxml = Widen(xml.str());
      DWORD reason = 0;
      const DWORD set = WlanSetProfile(handle, &guid, 0, wxml.c_str(), nullptr,
                                       TRUE, nullptr, &reason);
      if (set == ERROR_SUCCESS) {
        WLAN_CONNECTION_PARAMETERS params{};
        params.wlanConnectionMode = wlan_connection_mode_profile;
        const std::wstring wssid = Widen(ssid);
        params.strProfile = wssid.c_str();
        params.dot11BssType = dot11_BSS_type_infrastructure;
        ok = WlanConnect(handle, &guid, &params, nullptr) == ERROR_SUCCESS;
        if (ok) Sleep(2500);
      }
      WlanFreeMemory(list);
    }
    WlanCloseHandle(handle, nullptr);
    return ok;
  }

  void SaveCurrent(HANDLE handle, const GUID& guid) {
    previous_profile_.clear();
    DWORD size = 0;
    WLAN_OPCODE_VALUE_TYPE type{};
    PWLAN_CONNECTION_ATTRIBUTES attrs = nullptr;
    if (WlanQueryInterface(handle, &guid, wlan_intf_opcode_current_connection,
                           nullptr, &size, reinterpret_cast<PVOID*>(&attrs),
                           &type) == ERROR_SUCCESS &&
        attrs) {
      previous_profile_ = Narrow(attrs->strProfileName);
      WlanFreeMemory(attrs);
    }
  }

  void WlanLeave() {
    HANDLE handle = nullptr;
    DWORD version = 0;
    if (WlanOpenHandle(2, nullptr, &version, &handle) != ERROR_SUCCESS) return;
    PWLAN_INTERFACE_INFO_LIST list = nullptr;
    if (WlanEnumInterfaces(handle, nullptr, &list) == ERROR_SUCCESS && list &&
        list->dwNumberOfItems > 0) {
      const GUID guid = list->InterfaceInfo[0].InterfaceGuid;
      if (!joined_ssid_.empty()) {
        const std::wstring name = Widen(joined_ssid_);
        WlanDeleteProfile(handle, &guid, name.c_str(), nullptr);
      }
      if (!previous_profile_.empty()) {
        WLAN_CONNECTION_PARAMETERS params{};
        params.wlanConnectionMode = wlan_connection_mode_profile;
        const std::wstring prev = Widen(previous_profile_);
        params.strProfile = prev.c_str();
        params.dot11BssType = dot11_BSS_type_infrastructure;
        WlanConnect(handle, &guid, &params, nullptr);
      } else {
        WlanDisconnect(handle, &guid, nullptr);
      }
      WlanFreeMemory(list);
    }
    WlanCloseHandle(handle, nullptr);
    joined_ssid_.clear();
  }

  void SucceedConnect(const std::string& host, int port) {
    auto pending = std::move(pending_connect_);
    if (!pending) return;
    PostUi([pending = pending.release(), host, port]() mutable {
      MethodResult res(pending);
      res->Success(EncodableValue(EncodableMap{
          {EncodableValue("host"), EncodableValue(host)},
          {EncodableValue("port"), EncodableValue(port)},
      }));
    });
  }

  void FailConnect(const std::string& message) {
    auto pending = std::move(pending_connect_);
    if (!pending) return;
    PostUi([pending = pending.release(), message]() mutable {
      MethodResult(pending)->Error("link", message);
    });
  }

  void TeardownClient() {
    try {
      if (client_link_) {
        client_link_.WriteValueAsync(BytesToBuffer("{\"t\":\"done\"}"));
      }
    } catch (...) {
    }
    client_link_ = nullptr;
    WlanLeave();
  }

  void StopAll() {
    TeardownClient();
    StopAp();
    try {
      if (watcher_) watcher_.Stop();
    } catch (...) {
    }
    try {
      if (publisher_) publisher_.Stop();
    } catch (...) {
    }
    try {
      if (provider_) provider_.StopAdvertising();
    } catch (...) {
    }
    watcher_ = nullptr;
    publisher_ = nullptr;
    provider_ = nullptr;
    info_ = nullptr;
    link_ = nullptr;
  }

  HWND host_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::mutex mutex_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
  std::thread worker_;
  std::mutex work_mutex_;
  std::condition_variable work_cv_;
  std::queue<std::function<void()>> work_;
  bool stop_worker_ = false;

  std::string peer_id_;
  std::string name_;
  int http_port_ = 0;
  std::vector<uint8_t> beacon_;
  std::vector<uint8_t> name_bytes_;
  std::map<std::string, uint64_t> addresses_;
  MethodResult pending_connect_;
  std::string previous_profile_;
  std::string joined_ssid_;
  std::string ssid_;
  std::string psk_;

  wadv::BluetoothLEAdvertisementPublisher publisher_{nullptr};
  wadv::BluetoothLEAdvertisementWatcher watcher_{nullptr};
  wgatt::GattServiceProvider provider_{nullptr};
  wgatt::GattLocalCharacteristic info_{nullptr};
  wgatt::GattLocalCharacteristic link_{nullptr};
  wgatt::GattCharacteristic client_link_{nullptr};
  wfd::WiFiDirectAdvertisementPublisher ap_publisher_{nullptr};
};

DropP2pPlugin* g_plugin = nullptr;

}  // namespace

void RegisterDropP2pPlugin(flutter::BinaryMessenger* messenger,
                           HWND host_window) {
  delete g_plugin;
  g_plugin = new DropP2pPlugin(messenger, host_window);
}

bool DropP2pHandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  (void)hwnd;
  (void)wparam;
  if (!g_plugin) return false;
  return g_plugin->HandleMessage(message, lparam);
}
