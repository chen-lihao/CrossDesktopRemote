#ifndef RUNNER_WINDOWS_DEVICE_IDENTITY_BRIDGE_H_
#define RUNNER_WINDOWS_DEVICE_IDENTITY_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class WindowsDeviceIdentityBridge {
 public:
  explicit WindowsDeviceIdentityBridge(flutter::BinaryMessenger* messenger);
  ~WindowsDeviceIdentityBridge();

  WindowsDeviceIdentityBridge(const WindowsDeviceIdentityBridge&) = delete;
  WindowsDeviceIdentityBridge& operator=(const WindowsDeviceIdentityBridge&) =
      delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_DEVICE_IDENTITY_BRIDGE_H_
