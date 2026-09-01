#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <sstream>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT_PTR kDeferredFlutterRedrawTimer = 0x43445201;
constexpr UINT kDeferredFlutterRedrawDelayMs = 50;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  host_bridge_ = std::make_unique<WindowsHostBridge>(
      flutter_controller_->engine()->messenger());
  clipboard_bridge_ = std::make_unique<WindowsClipboardBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  file_paste_target_bridge_ =
      std::make_unique<WindowsFilePasteTargetBridge>(
          flutter_controller_->engine()->messenger(), GetHandle());
  lan_discovery_bridge_ = std::make_unique<WindowsLanDiscoveryBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.crossdesktopremote.cross_desktop_remote/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getMouseDoubleClickSettings") {
          const UINT dpi = GetDpiForWindow(GetHandle());
          const double scale = dpi == 0 ? 1.0 : static_cast<double>(dpi) / 96.0;
          flutter::EncodableMap settings;
          settings[flutter::EncodableValue("intervalMs")] =
              flutter::EncodableValue(
                  static_cast<int32_t>(GetDoubleClickTime()));
          settings[flutter::EncodableValue("width")] =
              flutter::EncodableValue(
                  static_cast<double>(GetSystemMetrics(SM_CXDOUBLECLK)) /
                  (2.0 * scale));
          settings[flutter::EncodableValue("height")] =
              flutter::EncodableValue(
                  static_cast<double>(GetSystemMetrics(SM_CYDOUBLECLK)) /
                  (2.0 * scale));
          result->Success(flutter::EncodableValue(settings));
          return;
        }
        if (call.method_name() != "setFullScreen") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Expected an argument map");
          return;
        }
        const auto enabled_entry =
            arguments->find(flutter::EncodableValue("enabled"));
        if (enabled_entry == arguments->end()) {
          result->Error("invalid_arguments", "Missing enabled flag");
          return;
        }
        const auto* enabled = std::get_if<bool>(&enabled_entry->second);
        if (enabled == nullptr) {
          result->Error("invalid_arguments", "Enabled flag must be boolean");
          return;
        }
        if (!SetFullscreen(*enabled)) {
          std::ostringstream details;
          details << "Win32 error " << GetLastError();
          result->Error("window_mode_failed",
                        "Unable to change the Windows window mode",
                        flutter::EncodableValue(details.str()));
          return;
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  KillTimer(GetHandle(), kDeferredFlutterRedrawTimer);
  lan_discovery_bridge_.reset();
  clipboard_bridge_.reset();
  file_paste_target_bridge_.reset();
  host_bridge_.reset();
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_TIMER && wparam == kDeferredFlutterRedrawTimer) {
    KillTimer(hwnd, kDeferredFlutterRedrawTimer);
    PerformFlutterRedraw();
    return 0;
  }

  switch (message) {
    case WM_SIZE: {
      const UINT next_state = static_cast<UINT>(wparam);
      if (next_state == SIZE_MINIMIZED) {
        minimized_ = true;
        if (last_size_state_ != SIZE_MINIMIZED) {
          EmitWindowLifecycleEvent("minimized");
        }
      } else {
        const bool was_minimized = minimized_;
        minimized_ = false;
        ScheduleFlutterRedraw();
        if (next_state == SIZE_MAXIMIZED &&
            last_size_state_ != SIZE_MAXIMIZED) {
          EmitWindowLifecycleEvent("maximized");
        } else if (next_state == SIZE_RESTORED &&
                   (was_minimized || last_size_state_ == SIZE_MAXIMIZED)) {
          EmitWindowLifecycleEvent("restored");
        }
      }
      last_size_state_ = next_state;
      break;
    }
    case WM_EXITSIZEMOVE:
      ScheduleFlutterRedraw();
      EmitWindowLifecycleEvent("resizeCompleted");
      break;
    case WM_DISPLAYCHANGE:
      ScheduleFlutterRedraw();
      EmitWindowLifecycleEvent("displayChanged");
      break;
  }

  if (lan_discovery_bridge_ &&
      lan_discovery_bridge_->HandleWindowMessage(message)) {
    return 0;
  }
  if (clipboard_bridge_ && clipboard_bridge_->HandleWindowMessage(message)) {
    return 0;
  }
  if (file_paste_target_bridge_ &&
      file_paste_target_bridge_->HandleWindowMessage(message, wparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ScheduleFlutterRedraw() {
  if (minimized_ || !flutter_controller_) {
    return;
  }
  flutter_controller_->ForceRedraw();
  SetTimer(GetHandle(), kDeferredFlutterRedrawTimer,
           kDeferredFlutterRedrawDelayMs, nullptr);
}

void FlutterWindow::PerformFlutterRedraw() {
  if (minimized_ || !flutter_controller_ || !flutter_controller_->view()) {
    return;
  }
  flutter_controller_->ForceRedraw();
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  RedrawWindow(flutter_view, nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
}

void FlutterWindow::EmitWindowLifecycleEvent(const std::string& event) {
  if (!window_channel_) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("event")] =
      flutter::EncodableValue(event);
  window_channel_->InvokeMethod(
      "windowStateChanged",
      std::make_unique<flutter::EncodableValue>(arguments));
}
