#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"
#include "windows_clipboard_bridge.h"
#include "windows_host_bridge.h"
#include "windows_lan_discovery_bridge.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ScheduleFlutterRedraw();
  void PerformFlutterRedraw();
  void EmitWindowLifecycleEvent(const std::string& event);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<WindowsHostBridge> host_bridge_;
  std::unique_ptr<WindowsClipboardBridge> clipboard_bridge_;
  std::unique_ptr<WindowsLanDiscoveryBridge> lan_discovery_bridge_;
  bool minimized_ = false;
  UINT last_size_state_ = SIZE_RESTORED;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
