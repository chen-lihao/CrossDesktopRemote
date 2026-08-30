#ifndef RUNNER_WINDOWS_HOST_BRIDGE_H_
#define RUNNER_WINDOWS_HOST_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <windows.h>

class WindowsHostBridge {
 public:
  explicit WindowsHostBridge(flutter::BinaryMessenger* messenger);
  ~WindowsHostBridge();

  WindowsHostBridge(const WindowsHostBridge&) = delete;
  WindowsHostBridge& operator=(const WindowsHostBridge&) = delete;

  // Releases every input state injected by this bridge. This is intentionally
  // used for disconnect and shutdown, rather than normal host-window focus
  // changes: a remote click commonly moves focus away from the host UI.
  void ReleaseAllInput();

  struct KeyDescriptor {
    UINT scan_code = 0;
    bool extended = false;
  };

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool HandlePointer(const flutter::EncodableMap& arguments,
                     std::string* error);
  bool HandleKeyboard(const flutter::EncodableMap& arguments,
                      std::string* error);
  bool HandleShortcut(const flutter::EncodableMap& arguments,
                      std::string* error);
  bool HandleText(const std::string& text, std::string* error);
  bool SetSyntheticModifiers(const std::set<UINT>& requested,
                             std::string* error);
  bool SendInputs(std::vector<INPUT>* inputs, std::string* error);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::set<std::string> pressed_mouse_buttons_;
  std::map<std::string, KeyDescriptor> pressed_keys_;
  std::set<UINT> pressed_modifiers_;
};

#endif  // RUNNER_WINDOWS_HOST_BRIDGE_H_
