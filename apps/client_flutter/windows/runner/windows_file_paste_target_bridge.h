#ifndef RUNNER_WINDOWS_FILE_PASTE_TARGET_BRIDGE_H_
#define RUNNER_WINDOWS_FILE_PASTE_TARGET_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <memory>
#include <windows.h>

class WindowsFilePasteTargetBridge {
 public:
  WindowsFilePasteTargetBridge(flutter::BinaryMessenger* messenger,
                               HWND window);
  ~WindowsFilePasteTargetBridge();

  WindowsFilePasteTargetBridge(const WindowsFilePasteTargetBridge&) = delete;
  WindowsFilePasteTargetBridge& operator=(
      const WindowsFilePasteTargetBridge&) = delete;

  bool HandleWindowMessage(UINT message, WPARAM wparam);

 private:
  using EncodableValue = flutter::EncodableValue;
  using FlutterResult = flutter::MethodResult<EncodableValue>;

  void CaptureActiveTarget(std::unique_ptr<FlutterResult> result);
  bool SetRemoteOfferAvailable(bool available);
  void RemoveKeyboardHook();
  bool ShouldInterceptPaste() const;
  LRESULT HandleKeyboardEvent(WPARAM message, const KBDLLHOOKSTRUCT& event);
  static LRESULT CALLBACK LowLevelKeyboardProc(int code, WPARAM wparam,
                                               LPARAM lparam);

  HWND window_ = nullptr;
  bool remote_offer_available_ = false;
  bool suppress_v_key_up_ = false;
  bool remove_hook_after_v_key_up_ = false;
  HHOOK keyboard_hook_ = nullptr;
  static WindowsFilePasteTargetBridge* active_bridge_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
};

#endif  // RUNNER_WINDOWS_FILE_PASTE_TARGET_BRIDGE_H_
