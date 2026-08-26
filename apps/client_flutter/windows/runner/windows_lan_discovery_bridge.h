#ifndef RUNNER_WINDOWS_LAN_DISCOVERY_BRIDGE_H_
#define RUNNER_WINDOWS_LAN_DISCOVERY_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include <winsock2.h>
#include <windows.h>
#include <windns.h>

class WindowsLanDiscoveryBridge {
 public:
  static constexpr UINT kDiscoveryChangedMessage = WM_APP + 0x4D2;

  WindowsLanDiscoveryBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsLanDiscoveryBridge();

  WindowsLanDiscoveryBridge(const WindowsLanDiscoveryBridge&) = delete;
  WindowsLanDiscoveryBridge& operator=(const WindowsLanDiscoveryBridge&) =
      delete;

  bool HandleWindowMessage(UINT message);

 private:
  struct BrowseContext;
  struct ResolveContext;
  struct RegistrationContext;

  struct Device {
    std::string id;
    std::string name;
    std::string host;
    int port = 0;
    std::string path;
    std::string version;
    std::string capabilities;
    std::string platform;
    std::string signaling_profile_id;
    std::string rendezvous_url;
  };

  enum class RegistrationOperation { kRegistering, kRegistered, kStopping };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartBrowsing(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopBrowsing(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void PublishHost(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopPublishing(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void GetDiagnostics(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static void WINAPI BrowseCallback(DWORD status, void* query_context,
                                    PDNS_RECORD records);
  static void WINAPI ResolveCallback(DWORD status, void* query_context,
                                     PDNS_SERVICE_INSTANCE instance);
  static void WINAPI RegistrationCallback(DWORD status, void* query_context,
                                          PDNS_SERVICE_INSTANCE instance);

  void OnBrowseResult(BrowseContext* context, DWORD status,
                      PDNS_RECORD records);
  void StartResolve(const std::wstring& service_name, ULONG interface_index,
                    uint64_t generation);
  void OnResolveResult(ResolveContext* context, DWORD status,
                       PDNS_SERVICE_INSTANCE instance);
  void OnRegistrationResult(RegistrationContext* context, DWORD status);
  void CompleteRegistrationOperation();
  void EmitDevices();
  void PostUpdate();
  void CancelAsyncOperations();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  HWND window_ = nullptr;

  std::mutex mutex_;
  std::condition_variable callbacks_finished_;
  std::map<std::string, Device> devices_;
  std::map<std::wstring, std::string> resolved_ids_;
  std::set<std::wstring> resolving_names_;
  std::vector<BrowseContext*> browse_contexts_;
  std::vector<ResolveContext*> resolve_contexts_;
  BrowseContext* current_browser_ = nullptr;
  RegistrationContext* registration_ = nullptr;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_registration_result_;
  DWORD pending_registration_status_ = ERROR_SUCCESS;
  bool registration_completion_pending_ = false;
  std::atomic<bool> shutting_down_{false};
  std::atomic<uint64_t> browse_generation_{0};
  uint64_t browse_callback_count_ = 0;
  uint64_t ptr_record_count_ = 0;
  uint64_t resolve_started_count_ = 0;
  uint64_t resolve_succeeded_count_ = 0;
  uint64_t registration_succeeded_count_ = 0;
  std::string active_registration_address_;
  std::string last_error_;
};

#endif  // RUNNER_WINDOWS_LAN_DISCOVERY_BRIDGE_H_
