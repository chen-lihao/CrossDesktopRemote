#include "windows_file_paste_target_bridge.h"

#include <exdisp.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <servprov.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cwchar>
#include <sstream>
#include <string>
#include <utility>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kMethodChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/file_paste_target";
constexpr char kEventChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/file_paste_intents";
constexpr UINT kRemoteFilePasteIntentMessage = WM_APP + 0x434;

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

HWND RootWindow(HWND window) {
  if (window == nullptr) return nullptr;
  const HWND root = GetAncestor(window, GA_ROOT);
  return root == nullptr ? window : root;
}

bool IsDesktopWindow(HWND window) {
  wchar_t class_name[64] = {};
  if (window == nullptr || GetClassNameW(window, class_name, 64) == 0) {
    return false;
  }
  return wcscmp(class_name, L"Progman") == 0 ||
         wcscmp(class_name, L"WorkerW") == 0;
}

bool IsExplorerWindow(HWND window) {
  wchar_t class_name[64] = {};
  if (window == nullptr || GetClassNameW(window, class_name, 64) == 0) {
    return false;
  }
  return wcscmp(class_name, L"CabinetWClass") == 0 ||
         wcscmp(class_name, L"ExploreWClass") == 0;
}

HRESULT ExplorerFolderForWindow(HWND foreground, std::wstring* path) {
  ComPtr<IShellWindows> shell_windows;
  HRESULT result = CoCreateInstance(CLSID_ShellWindows, nullptr,
                                    CLSCTX_LOCAL_SERVER,
                                    IID_PPV_ARGS(&shell_windows));
  if (FAILED(result)) return result;

  long count = 0;
  result = shell_windows->get_Count(&count);
  if (FAILED(result)) return result;

  const HWND foreground_root = RootWindow(foreground);
  for (long index = 0; index < count; ++index) {
    VARIANT item_index;
    VariantInit(&item_index);
    item_index.vt = VT_I4;
    item_index.lVal = index;
    ComPtr<IDispatch> dispatch;
    if (FAILED(shell_windows->Item(item_index, &dispatch)) || !dispatch) {
      continue;
    }

    ComPtr<IWebBrowserApp> browser;
    if (FAILED(dispatch.As(&browser)) || !browser) continue;
    SHANDLE_PTR raw_window = 0;
    if (FAILED(browser->get_HWND(&raw_window))) continue;
    const HWND explorer_window = reinterpret_cast<HWND>(raw_window);
    if (RootWindow(explorer_window) != foreground_root) continue;

    ComPtr<IServiceProvider> service_provider;
    if (FAILED(dispatch.As(&service_provider)) || !service_provider) continue;
    ComPtr<IShellBrowser> shell_browser;
    if (FAILED(service_provider->QueryService(
            SID_STopLevelBrowser, IID_PPV_ARGS(&shell_browser))) ||
        !shell_browser) {
      continue;
    }
    ComPtr<IShellView> shell_view;
    if (FAILED(shell_browser->QueryActiveShellView(&shell_view)) ||
        !shell_view) {
      continue;
    }
    ComPtr<IFolderView> folder_view;
    if (FAILED(shell_view.As(&folder_view)) || !folder_view) continue;
    ComPtr<IShellItem> folder;
    if (FAILED(folder_view->GetFolder(IID_PPV_ARGS(&folder))) || !folder) {
      continue;
    }
    PWSTR raw_path = nullptr;
    result = folder->GetDisplayName(SIGDN_FILESYSPATH, &raw_path);
    if (SUCCEEDED(result) && raw_path != nullptr) {
      *path = raw_path;
      CoTaskMemFree(raw_path);
      return S_OK;
    }
    if (raw_path != nullptr) CoTaskMemFree(raw_path);
  }
  return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

HRESULT DesktopFolder(std::wstring* path) {
  PWSTR raw_path = nullptr;
  const HRESULT result = SHGetKnownFolderPath(
      FOLDERID_Desktop, KF_FLAG_DEFAULT, nullptr, &raw_path);
  if (FAILED(result) || raw_path == nullptr) return result;
  *path = raw_path;
  CoTaskMemFree(raw_path);
  return S_OK;
}

bool DirectoryIdentity(const std::wstring& path, std::string* identity) {
  const HANDLE directory = CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (directory == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION information{};
  const BOOL succeeded = GetFileInformationByHandle(directory, &information);
  CloseHandle(directory);
  if (!succeeded) return false;
  std::ostringstream value;
  value << std::hex << information.dwVolumeSerialNumber << ':'
        << information.nFileIndexHigh << ':' << information.nFileIndexLow;
  *identity = value.str();
  return true;
}

bool DirectoryWritable(const std::wstring& path) {
  const HANDLE directory = CreateFileW(
      path.c_str(), FILE_ADD_FILE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (directory == INVALID_HANDLE_VALUE) return false;
  CloseHandle(directory);
  return true;
}

}  // namespace

WindowsFilePasteTargetBridge* WindowsFilePasteTargetBridge::active_bridge_ =
    nullptr;

WindowsFilePasteTargetBridge::WindowsFilePasteTargetBridge(
    flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kMethodChannel,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<FlutterResult> result) {
        if (call.method_name() == "setRemoteOfferAvailable") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Missing remote offer state");
            return;
          }
          const auto entry = arguments->find(EncodableValue("available"));
          const auto* available = entry == arguments->end()
                                      ? nullptr
                                      : std::get_if<bool>(&entry->second);
          if (available == nullptr) {
            result->Error("invalid_arguments", "Missing remote offer state");
            return;
          }
          if (!SetRemoteOfferAvailable(*available)) {
            result->Error("paste_shortcut_registration_failed",
                          "Unable to reserve Ctrl+V for remote file paste");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() != "captureActiveTarget") {
          if (call.method_name() == "validateTarget") {
            const auto* arguments =
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (arguments == nullptr) {
              result->Error("invalid_arguments", "Missing directory identity");
              return;
            }
            const auto path_entry = arguments->find(EncodableValue("path"));
            const auto identity_entry =
                arguments->find(EncodableValue("directoryIdentity"));
            const auto* path = path_entry == arguments->end()
                                   ? nullptr
                                   : std::get_if<std::string>(&path_entry->second);
            const auto* expected_identity =
                identity_entry == arguments->end()
                    ? nullptr
                    : std::get_if<std::string>(&identity_entry->second);
            if (path == nullptr || expected_identity == nullptr) {
              result->Error("invalid_arguments", "Missing directory identity");
              return;
            }
            const int wide_size = MultiByteToWideChar(
                CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
                static_cast<int>(path->size()), nullptr, 0);
            if (wide_size <= 0) {
              result->Success(EncodableValue(false));
              return;
            }
            std::wstring wide_path(static_cast<size_t>(wide_size), L'\0');
            MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
                                static_cast<int>(path->size()),
                                wide_path.data(), wide_size);
            std::string current_identity;
            result->Success(EncodableValue(
                DirectoryIdentity(wide_path, &current_identity) &&
                current_identity == *expected_identity &&
                DirectoryWritable(wide_path)));
            return;
          }
          result->NotImplemented();
          return;
        }
        CaptureActiveTarget(std::move(result));
      });
  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, kEventChannel, &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
            event_sink_ = std::move(sink);
            return std::unique_ptr<
                flutter::StreamHandlerError<EncodableValue>>();
          },
          [this](const EncodableValue*) {
            event_sink_.reset();
            return std::unique_ptr<
                flutter::StreamHandlerError<EncodableValue>>();
          }));
}

WindowsFilePasteTargetBridge::~WindowsFilePasteTargetBridge() {
  remote_offer_available_ = false;
  suppress_v_key_up_ = false;
  RemoveKeyboardHook();
  event_channel_->SetStreamHandler(nullptr);
  method_channel_->SetMethodCallHandler(nullptr);
}

bool WindowsFilePasteTargetBridge::HandleWindowMessage(UINT message,
                                                       WPARAM wparam) {
  static_cast<void>(wparam);
  if (message != kRemoteFilePasteIntentMessage || !remote_offer_available_) {
    return false;
  }
  if (event_sink_) event_sink_->Success(EncodableValue());
  return true;
}

bool WindowsFilePasteTargetBridge::SetRemoteOfferAvailable(bool available) {
  if (remote_offer_available_ == available) {
    if (available) remove_hook_after_v_key_up_ = false;
    return true;
  }
  if (!available) {
    remote_offer_available_ = false;
    if (suppress_v_key_up_) {
      remove_hook_after_v_key_up_ = true;
    } else {
      RemoveKeyboardHook();
    }
    return true;
  }
  remove_hook_after_v_key_up_ = false;
  if (keyboard_hook_ != nullptr && active_bridge_ == this) {
    remote_offer_available_ = true;
    return true;
  }
  if (active_bridge_ != nullptr && active_bridge_ != this) return false;
  active_bridge_ = this;
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc,
                                     GetModuleHandleW(nullptr), 0);
  if (keyboard_hook_ == nullptr) {
    active_bridge_ = nullptr;
    return false;
  }
  remote_offer_available_ = true;
  return true;
}

void WindowsFilePasteTargetBridge::RemoveKeyboardHook() {
  remove_hook_after_v_key_up_ = false;
  if (keyboard_hook_ != nullptr) {
    UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
  if (active_bridge_ == this) active_bridge_ = nullptr;
}

bool WindowsFilePasteTargetBridge::ShouldInterceptPaste() const {
  const HWND foreground = RootWindow(GetForegroundWindow());
  return IsDesktopWindow(foreground) || IsExplorerWindow(foreground);
}

LRESULT WindowsFilePasteTargetBridge::HandleKeyboardEvent(
    WPARAM message, const KBDLLHOOKSTRUCT& event) {
  if (event.vkCode != static_cast<DWORD>('V')) return 0;
  const bool is_key_down =
      message == static_cast<WPARAM>(WM_KEYDOWN) ||
      message == static_cast<WPARAM>(WM_SYSKEYDOWN);
  const bool is_key_up =
      message == static_cast<WPARAM>(WM_KEYUP) ||
      message == static_cast<WPARAM>(WM_SYSKEYUP);
  if (is_key_up && suppress_v_key_up_) {
    suppress_v_key_up_ = false;
    if (remove_hook_after_v_key_up_) RemoveKeyboardHook();
    return 1;
  }
  if (is_key_down && suppress_v_key_up_) {
    return 1;
  }
  if (!is_key_down || !remote_offer_available_ || !ShouldInterceptPaste()) {
    return 0;
  }
  const bool control_down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool alt_down = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool windows_down = (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 ||
                            (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
  if (!control_down || alt_down || shift_down || windows_down) return 0;
  suppress_v_key_up_ = true;
  PostMessageW(window_, kRemoteFilePasteIntentMessage, 0, 0);
  return 1;
}

LRESULT CALLBACK WindowsFilePasteTargetBridge::LowLevelKeyboardProc(
    int code, WPARAM wparam, LPARAM lparam) {
  auto* bridge = active_bridge_;
  if (code == HC_ACTION && bridge != nullptr && lparam != 0) {
    const auto* event = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    const LRESULT handled = bridge->HandleKeyboardEvent(wparam, *event);
    if (handled != 0) return handled;
  }
  return CallNextHookEx(bridge == nullptr ? nullptr : bridge->keyboard_hook_,
                        code, wparam, lparam);
}

void WindowsFilePasteTargetBridge::CaptureActiveTarget(
    std::unique_ptr<FlutterResult> result) {
  const HRESULT initialize =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool uninitialize = SUCCEEDED(initialize);
  const HWND foreground = GetForegroundWindow();
  std::wstring path;
  HRESULT resolution = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  if (IsDesktopWindow(RootWindow(foreground))) {
    resolution = DesktopFolder(&path);
  } else {
    resolution = ExplorerFolderForWindow(foreground, &path);
  }
  if (uninitialize) CoUninitialize();

  const DWORD attributes = path.empty()
                               ? INVALID_FILE_ATTRIBUTES
                               : GetFileAttributesW(path.c_str());
  if (FAILED(resolution) || attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    result->Error("unsupported_paste_target",
                  "请先在文件资源管理器中打开并激活目标目录");
    return;
  }
  std::string directory_identity;
  if (!DirectoryIdentity(path, &directory_identity)) {
    result->Error("paste_target_identity_unavailable",
                  "Unable to verify the active Explorer folder identity");
    return;
  }
  const bool writable = DirectoryWritable(path);
  if (!writable) {
    result->Error("paste_target_not_writable",
                  "The active Explorer folder is not writable");
    return;
  }

  std::wstring display_name = path;
  while (display_name.size() > 1 &&
         (display_name.back() == L'\\' || display_name.back() == L'/')) {
    display_name.pop_back();
  }
  const size_t separator = display_name.find_last_of(L"\\/");
  if (separator != std::wstring::npos && separator + 1 < display_name.size()) {
    display_name = display_name.substr(separator + 1);
  }
  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("path"), EncodableValue(Utf8FromWide(path))},
      {EncodableValue("displayName"),
       EncodableValue(Utf8FromWide(display_name))},
      {EncodableValue("application"), EncodableValue("Explorer")},
      {EncodableValue("directoryIdentity"),
       EncodableValue(directory_identity)},
      {EncodableValue("writable"), EncodableValue(writable)},
  }));
}
