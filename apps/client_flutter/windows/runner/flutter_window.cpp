#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <sstream>

#include "flutter/generated_plugin_registrant.h"

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
  lan_discovery_bridge_.reset();
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
  if (lan_discovery_bridge_ &&
      lan_discovery_bridge_->HandleWindowMessage(message)) {
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
