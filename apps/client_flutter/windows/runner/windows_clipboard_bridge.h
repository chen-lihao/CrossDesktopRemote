#ifndef RUNNER_WINDOWS_CLIPBOARD_BRIDGE_H_
#define RUNNER_WINDOWS_CLIPBOARD_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>
#include <windows.h>

class WindowsClipboardBridge {
 public:
  WindowsClipboardBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsClipboardBridge();

  WindowsClipboardBridge(const WindowsClipboardBridge&) = delete;
  WindowsClipboardBridge& operator=(const WindowsClipboardBridge&) = delete;

  bool HandleWindowMessage(UINT message);

 private:
  using EncodableValue = flutter::EncodableValue;
  using FlutterResult = flutter::MethodResult<EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<FlutterResult> result);
  EncodableValue Snapshot();
  bool OpenClipboardWithRetry();
  void EmitSnapshot();

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
};

#endif  // RUNNER_WINDOWS_CLIPBOARD_BRIDGE_H_
