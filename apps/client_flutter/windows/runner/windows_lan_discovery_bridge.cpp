#include "windows_lan_discovery_bridge.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <iterator>
#include <limits>
#include <optional>
#include <utility>

#include <iphlpapi.h>
#include <ws2tcpip.h>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using FlutterResult = flutter::MethodResult<EncodableValue>;

constexpr char kMethodChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/lan_discovery";
constexpr char kEventChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/lan_discovery_events";
constexpr wchar_t kServiceQuery[] = L"_cdrremote._tcp.local";
constexpr wchar_t kServiceSuffix[] = L"._cdrremote._tcp.local";

const EncodableValue* FindValue(const EncodableMap& values,
                                const char* key) {
  const auto entry = values.find(EncodableValue(key));
  return entry == values.end() ? nullptr : &entry->second;
}

std::string StringValue(const EncodableMap& values, const char* key,
                        const std::string& fallback = {}) {
  const auto* value = FindValue(values, key);
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return text == nullptr ? fallback : *text;
}

int64_t IntegerValue(const EncodableMap& values, const char* key) {
  const auto* value = FindValue(values, key);
  if (value == nullptr) {
    return 0;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return *integer;
  }
  return 0;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

std::wstring ComputerHostName() {
  wchar_t name[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD length = static_cast<DWORD>(std::size(name));
  if (!GetComputerNameW(name, &length) || length == 0) {
    return L"crossdesktopremote.local";
  }
  return std::wstring(name, length) + L".local";
}

struct ActiveIPv4Address {
  IP4_ADDRESS value = 0;
  std::string text;
  ULONG route_metric = std::numeric_limits<ULONG>::max();
  bool physical_interface = false;
  bool private_address = false;
};

std::optional<ActiveIPv4Address> FindActiveIPv4Address() {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> storage(size);
  auto* adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(storage.data());
  ULONG status = GetAdaptersAddresses(
      AF_INET,
      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
          GAA_FLAG_SKIP_DNS_SERVER,
      nullptr, adapters, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    storage.resize(size);
    adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(storage.data());
    status = GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
            GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &size);
  }
  if (status != NO_ERROR) {
    return std::nullopt;
  }
  std::optional<ActiveIPv4Address> best;
  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK ||
        adapter->IfType == IF_TYPE_TUNNEL ||
        (adapter->Flags & IP_ADAPTER_NO_MULTICAST) != 0) {
      continue;
    }
    for (auto* unicast = adapter->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      if (unicast->Address.lpSockaddr == nullptr ||
          unicast->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      auto* address = reinterpret_cast<sockaddr_in*>(
          unicast->Address.lpSockaddr);
      const auto host_order = ntohl(address->sin_addr.S_un.S_addr);
      const auto first = static_cast<unsigned int>((host_order >> 24) & 0xff);
      const auto second = static_cast<unsigned int>((host_order >> 16) & 0xff);
      if (first == 0 || first == 127 || (first == 169 && second == 254)) {
        continue;
      }
      char text[INET_ADDRSTRLEN]{};
      if (InetNtopA(AF_INET, &address->sin_addr, text,
                    static_cast<DWORD>(std::size(text))) == nullptr) {
        continue;
      }
      const bool private_address =
          first == 10 || (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168);
      const bool physical_interface =
          adapter->IfType == IF_TYPE_ETHERNET_CSMACD ||
          adapter->IfType == IF_TYPE_IEEE80211;
      ActiveIPv4Address candidate{address->sin_addr.S_un.S_addr,
                                  text,
                                  adapter->Ipv4Metric,
                                  physical_interface,
                                  private_address};
      const bool is_better =
          !best.has_value() ||
          candidate.route_metric < best->route_metric ||
          (candidate.route_metric == best->route_metric &&
           candidate.physical_interface && !best->physical_interface) ||
          (candidate.route_metric == best->route_metric &&
           candidate.physical_interface == best->physical_interface &&
           candidate.private_address && !best->private_address);
      if (is_better) {
        best = std::move(candidate);
      }
    }
  }
  return best;
}

std::string ServiceDisplayName(const std::wstring& full_name) {
  const auto suffix = full_name.find(kServiceSuffix);
  return Utf8FromUtf16(
      (suffix == std::wstring::npos ? full_name : full_name.substr(0, suffix))
          .c_str());
}

std::string Property(PDNS_SERVICE_INSTANCE instance, const wchar_t* key,
                     const std::string& fallback = {}) {
  if (instance == nullptr || instance->keys == nullptr ||
      instance->values == nullptr) {
    return fallback;
  }
  for (DWORD index = 0; index < instance->dwPropertyCount; ++index) {
    if (instance->keys[index] != nullptr &&
        wcscmp(instance->keys[index], key) == 0) {
      return Utf8FromUtf16(instance->values[index]);
    }
  }
  return fallback;
}

template <typename Status>
std::string DnsError(Status status) {
  return "Windows DNS-SD error " +
         std::to_string(static_cast<long long>(status));
}

}  // namespace

struct WindowsLanDiscoveryBridge::BrowseContext {
  std::atomic<WindowsLanDiscoveryBridge*> owner{nullptr};
  uint64_t generation = 0;
  DNS_SERVICE_BROWSE_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};
};

struct WindowsLanDiscoveryBridge::ResolveContext {
  std::atomic<WindowsLanDiscoveryBridge*> owner{nullptr};
  uint64_t generation = 0;
  std::wstring query_name;
  DNS_SERVICE_RESOLVE_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};
};

struct WindowsLanDiscoveryBridge::RegistrationContext {
  std::atomic<WindowsLanDiscoveryBridge*> owner{nullptr};
  RegistrationOperation operation = RegistrationOperation::kRegistering;
  DNS_SERVICE_REGISTER_REQUEST request{};
  DNS_SERVICE_CANCEL cancel{};
  PDNS_SERVICE_INSTANCE instance = nullptr;
  std::wstring instance_name;
  std::wstring host_name;
  std::string address;
  std::vector<std::wstring> property_keys;
  std::vector<std::wstring> property_values;
  std::vector<PCWSTR> key_pointers;
  std::vector<PCWSTR> value_pointers;
};

WindowsLanDiscoveryBridge::WindowsLanDiscoveryBridge(
    flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kMethodChannel,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<FlutterResult> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, kEventChannel, &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
            event_sink_ = std::move(sink);
            EmitDevices();
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          },
          [this](const EncodableValue*) {
            event_sink_.reset();
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          }));
}

WindowsLanDiscoveryBridge::~WindowsLanDiscoveryBridge() {
  CancelAsyncOperations();
  event_channel_->SetStreamHandler(nullptr);
  method_channel_->SetMethodCallHandler(nullptr);
}

void WindowsLanDiscoveryBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<FlutterResult> result) {
  if (call.method_name() == "startBrowsing") {
    StartBrowsing(std::move(result));
    return;
  }
  if (call.method_name() == "stopBrowsing") {
    StopBrowsing(std::move(result));
    return;
  }
  if (call.method_name() == "stopPublishing") {
    StopPublishing(std::move(result));
    return;
  }
  if (call.method_name() == "getDiagnostics") {
    GetDiagnostics(std::move(result));
    return;
  }
  if (call.method_name() != "publishHost") {
    result->NotImplemented();
    return;
  }
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_advertisement", "Expected an argument map");
    return;
  }
  PublishHost(*arguments, std::move(result));
}

void WindowsLanDiscoveryBridge::StartBrowsing(
    std::unique_ptr<FlutterResult> result) {
  if (current_browser_ != nullptr) {
    result->Success();
    return;
  }
  auto* context = new BrowseContext();
  context->owner = this;
  context->generation = ++browse_generation_;
  context->request.Version = DNS_QUERY_REQUEST_VERSION1;
  context->request.InterfaceIndex = 0;
  context->request.QueryName = kServiceQuery;
  context->request.pBrowseCallback = BrowseCallback;
  context->request.pQueryContext = context;
  const DNS_STATUS status =
      DnsServiceBrowse(&context->request, &context->cancel);
  if (status != DNS_REQUEST_PENDING) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      last_error_ = DnsError(status);
    }
    delete context;
    result->Error("dns_sd_browse_failed", DnsError(status));
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    browse_contexts_.push_back(context);
    current_browser_ = context;
    browse_callback_count_ = 0;
    ptr_record_count_ = 0;
    resolve_started_count_ = 0;
    resolve_succeeded_count_ = 0;
    last_error_.clear();
  }
  result->Success();
}

void WindowsLanDiscoveryBridge::GetDiagnostics(
    std::unique_ptr<FlutterResult> result) {
  std::lock_guard<std::mutex> lock(mutex_);
  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("browsing"),
       EncodableValue(current_browser_ != nullptr)},
      {EncodableValue("publishing"),
       EncodableValue(registration_ != nullptr &&
                      registration_->operation ==
                          RegistrationOperation::kRegistered)},
      {EncodableValue("discoveredCount"),
       EncodableValue(static_cast<int32_t>(devices_.size()))},
      {EncodableValue("resolvingCount"),
       EncodableValue(static_cast<int32_t>(resolving_names_.size()))},
      {EncodableValue("browseCallbackCount"),
       EncodableValue(static_cast<int64_t>(browse_callback_count_))},
      {EncodableValue("ptrRecordCount"),
       EncodableValue(static_cast<int64_t>(ptr_record_count_))},
      {EncodableValue("resolveStartedCount"),
       EncodableValue(static_cast<int64_t>(resolve_started_count_))},
      {EncodableValue("resolveSucceededCount"),
       EncodableValue(static_cast<int64_t>(resolve_succeeded_count_))},
      {EncodableValue("registrationSucceededCount"),
       EncodableValue(static_cast<int64_t>(registration_succeeded_count_))},
      {EncodableValue("activeRegistrationAddress"),
       EncodableValue(active_registration_address_)},
      {EncodableValue("lastError"), EncodableValue(last_error_)},
  }));
}

void WindowsLanDiscoveryBridge::StopBrowsing(
    std::unique_ptr<FlutterResult> result) {
  BrowseContext* context = nullptr;
  std::vector<ResolveContext*> resolutions;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    context = current_browser_;
    current_browser_ = nullptr;
    ++browse_generation_;
    resolutions = resolve_contexts_;
    devices_.clear();
    resolved_ids_.clear();
    resolving_names_.clear();
  }
  if (context != nullptr) {
    DnsServiceBrowseCancel(&context->cancel);
  }
  for (auto* resolution : resolutions) {
    DnsServiceResolveCancel(&resolution->cancel);
  }
  EmitDevices();
  result->Success();
}

void WindowsLanDiscoveryBridge::PublishHost(
    const EncodableMap& arguments, std::unique_ptr<FlutterResult> result) {
  if (registration_ != nullptr || pending_registration_result_ != nullptr) {
    result->Error("dns_sd_busy", "Windows DNS-SD registration is busy");
    return;
  }
  const std::string device_id = StringValue(arguments, "deviceId");
  const std::string name = StringValue(arguments, "name");
  const int64_t port = IntegerValue(arguments, "port");
  if (device_id.empty() || name.empty() || port <= 0 || port > 65535) {
    result->Error("invalid_advertisement", "Invalid LAN host advertisement");
    return;
  }

  auto* context = new RegistrationContext();
  context->owner = this;
  context->instance_name = WideFromUtf8(name) + kServiceSuffix;
  context->host_name = ComputerHostName();
  auto active_address = FindActiveIPv4Address();
  if (!active_address.has_value()) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      last_error_ =
          "No active multicast-capable IPv4 interface is available";
    }
    delete context;
    result->Error(
        "dns_sd_no_interface",
        "No active multicast-capable IPv4 interface is available");
    return;
  }
  context->address = active_address->text;
  context->property_keys = {L"id", L"v", L"path", L"cap", L"platform",
                            L"signal", L"signalUrl"};
  context->property_values = {
      WideFromUtf8(device_id),
      WideFromUtf8(StringValue(arguments, "version", "1")),
      WideFromUtf8(StringValue(arguments, "path", "/ws/signaling")),
      WideFromUtf8(StringValue(arguments, "capabilities")),
      WideFromUtf8(StringValue(arguments, "platform", "windows")),
      WideFromUtf8(StringValue(arguments, "signalingProfileId")),
      WideFromUtf8(StringValue(arguments, "rendezvousUrl"))};
  for (const auto& key : context->property_keys) {
    context->key_pointers.push_back(key.c_str());
  }
  for (const auto& value : context->property_values) {
    context->value_pointers.push_back(value.c_str());
  }
  context->instance = DnsServiceConstructInstance(
      context->instance_name.c_str(), context->host_name.c_str(),
      &active_address->value,
      nullptr, static_cast<WORD>(port), 0, 0,
      static_cast<DWORD>(context->key_pointers.size()),
      context->key_pointers.data(), context->value_pointers.data());
  if (context->instance == nullptr) {
    delete context;
    result->Error("dns_sd_register_failed",
                  "Unable to construct the Windows DNS-SD service");
    return;
  }
  context->request.Version = DNS_QUERY_REQUEST_VERSION1;
  context->request.InterfaceIndex = 0;
  context->request.pServiceInstance = context->instance;
  context->request.pRegisterCompletionCallback = RegistrationCallback;
  context->request.pQueryContext = context;
  context->request.unicastEnabled = FALSE;

  registration_ = context;
  pending_registration_result_ = std::move(result);
  const DWORD status =
      DnsServiceRegister(&context->request, &context->cancel);
  if (status != DNS_REQUEST_PENDING) {
    auto pending = std::move(pending_registration_result_);
    registration_ = nullptr;
    DnsServiceFreeInstance(context->instance);
    delete context;
    pending->Error("dns_sd_register_failed", DnsError(status));
  }
}

void WindowsLanDiscoveryBridge::StopPublishing(
    std::unique_ptr<FlutterResult> result) {
  auto* context = registration_;
  if (context == nullptr) {
    result->Success();
    return;
  }
  if (pending_registration_result_ != nullptr) {
    result->Error("dns_sd_busy", "Windows DNS-SD registration is busy");
    return;
  }
  context->operation = RegistrationOperation::kStopping;
  pending_registration_result_ = std::move(result);
  const DWORD status = DnsServiceDeRegister(&context->request, nullptr);
  if (status != DNS_REQUEST_PENDING) {
    auto pending = std::move(pending_registration_result_);
    context->operation = RegistrationOperation::kRegistered;
    pending->Error("dns_sd_deregister_failed", DnsError(status));
  }
}

void WINAPI WindowsLanDiscoveryBridge::BrowseCallback(
    DWORD status, void* query_context, PDNS_RECORD records) {
  auto* context = static_cast<BrowseContext*>(query_context);
  auto* owner = context == nullptr ? nullptr : context->owner.load();
  if (owner != nullptr) {
    owner->OnBrowseResult(context, status, records);
  } else {
    if (records != nullptr) {
      DnsRecordListFree(records, DnsFreeRecordList);
    }
    if (context != nullptr && status == ERROR_CANCELLED) {
      delete context;
    }
  }
}

void WindowsLanDiscoveryBridge::OnBrowseResult(BrowseContext* context,
                                                DWORD status,
                                                PDNS_RECORD records) {
  if (status == ERROR_CANCELLED) {
    if (records != nullptr) {
      DnsRecordListFree(records, DnsFreeRecordList);
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (current_browser_ == context) {
      current_browser_ = nullptr;
    }
    browse_contexts_.erase(
        std::remove(browse_contexts_.begin(), browse_contexts_.end(), context),
        browse_contexts_.end());
    callbacks_finished_.notify_all();
    delete context;
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    browse_callback_count_ += 1;
  }
  if (status == ERROR_SUCCESS &&
      context->generation == browse_generation_.load()) {
    for (auto* record = records; record != nullptr; record = record->pNext) {
      if (record->wType != DNS_TYPE_PTR || record->Data.PTR.pNameHost == nullptr) {
        continue;
      }
      const std::wstring service_name(record->Data.PTR.pNameHost);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        ptr_record_count_ += 1;
      }
      if (record->dwTtl == 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto id = resolved_ids_.find(service_name);
        if (id != resolved_ids_.end()) {
          devices_.erase(id->second);
          resolved_ids_.erase(id);
        }
        PostUpdate();
      } else {
        // InterfaceIndex 0 asks WinDNS to resolve on every eligible interface.
        // The instance name remains the de-duplication key across Wi-Fi,
        // Ethernet and VPN adapters.
        StartResolve(service_name, 0, context->generation);
      }
    }
  }
  if (records != nullptr) {
    DnsRecordListFree(records, DnsFreeRecordList);
  }
}

void WindowsLanDiscoveryBridge::StartResolve(
    const std::wstring& service_name, ULONG interface_index,
    uint64_t generation) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != browse_generation_.load() ||
        !resolving_names_.insert(service_name).second) {
      return;
    }
    resolve_started_count_ += 1;
  }
  auto* context = new ResolveContext();
  context->owner = this;
  context->generation = generation;
  context->query_name = service_name;
  context->request.Version = DNS_QUERY_REQUEST_VERSION1;
  context->request.InterfaceIndex = interface_index;
  context->request.QueryName = context->query_name.data();
  context->request.pResolveCompletionCallback = ResolveCallback;
  context->request.pQueryContext = context;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    resolve_contexts_.push_back(context);
  }
  const DNS_STATUS status =
      DnsServiceResolve(&context->request, &context->cancel);
  if (status != DNS_REQUEST_PENDING) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_ = DnsError(status);
    resolve_contexts_.erase(std::remove(resolve_contexts_.begin(),
                                        resolve_contexts_.end(), context),
                            resolve_contexts_.end());
    resolving_names_.erase(service_name);
    delete context;
  }
}

void WINAPI WindowsLanDiscoveryBridge::ResolveCallback(
    DWORD status, void* query_context, PDNS_SERVICE_INSTANCE instance) {
  auto* context = static_cast<ResolveContext*>(query_context);
  auto* owner = context == nullptr ? nullptr : context->owner.load();
  if (owner != nullptr) {
    owner->OnResolveResult(context, status, instance);
  } else {
    if (instance != nullptr) {
      DnsServiceFreeInstance(instance);
    }
    delete context;
  }
}

void WindowsLanDiscoveryBridge::OnResolveResult(
    ResolveContext* context, DWORD status, PDNS_SERVICE_INSTANCE instance) {
  if (status == ERROR_SUCCESS && instance != nullptr &&
      context->generation == browse_generation_.load()) {
    Device device;
    device.id = Property(instance, L"id", Utf8FromUtf16(instance->pszInstanceName));
    device.name = ServiceDisplayName(context->query_name);
    device.host = Utf8FromUtf16(instance->pszHostName);
    device.port = static_cast<int>(instance->wPort);
    device.path = Property(instance, L"path", "/ws/signaling");
    device.version = Property(instance, L"v", "1");
    device.capabilities = Property(instance, L"cap");
    device.platform = Property(instance, L"platform", "unknown");
    device.signaling_profile_id = Property(instance, L"signal");
    device.rendezvous_url = Property(instance, L"signalUrl");
    if (!device.id.empty() && !device.host.empty() && device.port > 0) {
      std::lock_guard<std::mutex> lock(mutex_);
      resolved_ids_[context->query_name] = device.id;
      devices_[device.id] = std::move(device);
      resolve_succeeded_count_ += 1;
      PostUpdate();
    }
  } else if (status != ERROR_CANCELLED) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_ = DnsError(status);
  }
  if (instance != nullptr) {
    DnsServiceFreeInstance(instance);
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    resolving_names_.erase(context->query_name);
    resolve_contexts_.erase(std::remove(resolve_contexts_.begin(),
                                        resolve_contexts_.end(), context),
                            resolve_contexts_.end());
    callbacks_finished_.notify_all();
  }
  delete context;
}

void WINAPI WindowsLanDiscoveryBridge::RegistrationCallback(
    DWORD status, void* query_context, PDNS_SERVICE_INSTANCE instance) {
  auto* context = static_cast<RegistrationContext*>(query_context);
  // WinDNS returns a separately allocated copy for both register and
  // deregister completions. It is not the request-owned instance below.
  if (instance != nullptr) {
    DnsServiceFreeInstance(instance);
  }
  auto* owner = context == nullptr ? nullptr : context->owner.load();
  if (owner != nullptr) {
    owner->OnRegistrationResult(context, status);
  } else if (context != nullptr) {
    DnsServiceFreeInstance(context->instance);
    delete context;
  }
}

void WindowsLanDiscoveryBridge::OnRegistrationResult(
    RegistrationContext* context, DWORD status) {
  if (shutting_down_.load()) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (context == registration_) {
        registration_ = nullptr;
      }
      callbacks_finished_.notify_all();
    }
    DnsServiceFreeInstance(context->instance);
    delete context;
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context != registration_) {
      return;
    }
    pending_registration_status_ = status;
    registration_completion_pending_ = true;
  }
  PostUpdate();
}

bool WindowsLanDiscoveryBridge::HandleWindowMessage(UINT message) {
  if (message != kDiscoveryChangedMessage) {
    return false;
  }
  CompleteRegistrationOperation();
  EmitDevices();
  return true;
}

void WindowsLanDiscoveryBridge::CompleteRegistrationOperation() {
  std::unique_ptr<FlutterResult> pending;
  DWORD status = ERROR_SUCCESS;
  RegistrationContext* context = nullptr;
  RegistrationOperation operation = RegistrationOperation::kRegistering;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!registration_completion_pending_) {
      return;
    }
    registration_completion_pending_ = false;
    pending = std::move(pending_registration_result_);
    status = pending_registration_status_;
    context = registration_;
    if (context != nullptr) {
      operation = context->operation;
    }
  }
  if (context == nullptr) {
    if (pending != nullptr) {
      pending->Error("dns_sd_register_failed", "Registration disappeared");
    }
    return;
  }
  if (operation == RegistrationOperation::kRegistering &&
      status == ERROR_SUCCESS) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      context->operation = RegistrationOperation::kRegistered;
      registration_succeeded_count_ += 1;
      active_registration_address_ = context->address;
      last_error_.clear();
    }
    if (pending != nullptr) {
      pending->Success();
    }
    return;
  }
  if (operation == RegistrationOperation::kStopping &&
      status == ERROR_SUCCESS) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      registration_ = nullptr;
      active_registration_address_.clear();
    }
    if (pending != nullptr) {
      pending->Success();
    }
    DnsServiceFreeInstance(context->instance);
    delete context;
    callbacks_finished_.notify_all();
    return;
  }
  if (pending != nullptr) {
    pending->Error(operation == RegistrationOperation::kStopping
                       ? "dns_sd_deregister_failed"
                       : "dns_sd_register_failed",
                   DnsError(status));
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_ = DnsError(status);
  }
  if (operation == RegistrationOperation::kRegistering) {
    registration_ = nullptr;
    DnsServiceFreeInstance(context->instance);
    delete context;
  } else {
    context->operation = RegistrationOperation::kRegistered;
  }
}

void WindowsLanDiscoveryBridge::EmitDevices() {
  if (event_sink_ == nullptr) {
    return;
  }
  EncodableList values;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    values.reserve(devices_.size());
    for (const auto& entry : devices_) {
      const Device& device = entry.second;
      values.emplace_back(EncodableMap{
          {EncodableValue("id"), EncodableValue(device.id)},
          {EncodableValue("name"), EncodableValue(device.name)},
          {EncodableValue("host"), EncodableValue(device.host)},
          {EncodableValue("port"), EncodableValue(device.port)},
          {EncodableValue("path"), EncodableValue(device.path)},
          {EncodableValue("version"), EncodableValue(device.version)},
          {EncodableValue("capabilities"),
           EncodableValue(device.capabilities)},
          {EncodableValue("platform"), EncodableValue(device.platform)},
          {EncodableValue("signalingProfileId"),
           EncodableValue(device.signaling_profile_id)},
          {EncodableValue("rendezvousUrl"),
           EncodableValue(device.rendezvous_url)},
      });
    }
  }
  event_sink_->Success(EncodableValue(values));
}

void WindowsLanDiscoveryBridge::PostUpdate() {
  if (!shutting_down_.load() && window_ != nullptr) {
    PostMessage(window_, kDiscoveryChangedMessage, 0, 0);
  }
}

void WindowsLanDiscoveryBridge::CancelAsyncOperations() {
  std::vector<BrowseContext*> browsers;
  std::vector<ResolveContext*> resolutions;
  RegistrationContext* registration = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    shutting_down_.store(true);
    ++browse_generation_;
    browsers = browse_contexts_;
    resolutions = resolve_contexts_;
    registration = registration_;
  }
  for (auto* browser : browsers) {
    DnsServiceBrowseCancel(&browser->cancel);
  }
  for (auto* resolution : resolutions) {
    DnsServiceResolveCancel(&resolution->cancel);
  }
  if (registration != nullptr) {
    if (registration->operation == RegistrationOperation::kRegistered) {
      registration->operation = RegistrationOperation::kStopping;
      DnsServiceDeRegister(&registration->request, nullptr);
    } else if (registration->operation ==
               RegistrationOperation::kRegistering) {
      DnsServiceRegisterCancel(&registration->cancel);
    }
  }
  std::unique_lock<std::mutex> lock(mutex_);
  callbacks_finished_.wait_for(lock, std::chrono::seconds(2), [this] {
    return browse_contexts_.empty() && resolve_contexts_.empty() &&
           registration_ == nullptr;
  });
  for (auto* context : browse_contexts_) {
    context->owner.store(nullptr);
  }
  for (auto* context : resolve_contexts_) {
    context->owner.store(nullptr);
  }
  if (registration_ != nullptr) {
    registration_->owner.store(nullptr);
  }
}
