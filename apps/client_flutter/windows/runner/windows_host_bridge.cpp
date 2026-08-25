#include "windows_host_bridge.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <sstream>
#include <utility>

#include <shellscalingapi.h>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kInputChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/input";
constexpr int32_t kHostProtocolVersion = 1;
constexpr char kUipiLimitation[] =
    "Windows 安全限制：当前仅能控制同等或更低权限窗口，管理员/UAC安全桌面不受支持";

struct DisplayInfo {
  std::string id;
  std::string name;
  RECT bounds{};
  double scale = 1.0;
  bool primary = false;
};

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::vector<DisplayInfo> EnumerateDisplays() {
  std::vector<DisplayInfo> displays;
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM context) -> BOOL {
        auto* values =
            reinterpret_cast<std::vector<DisplayInfo>*>(context);
        MONITORINFOEXW monitor_info{};
        monitor_info.cbSize = sizeof(monitor_info);
        if (!GetMonitorInfoW(
                monitor, reinterpret_cast<LPMONITORINFO>(&monitor_info))) {
          return TRUE;
        }

        UINT dpi_x = 96;
        UINT dpi_y = 96;
        if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x,
                                    &dpi_y))) {
          dpi_x = 96;
        }

        DisplayInfo display;
        display.id = Utf8FromWide(monitor_info.szDevice);
        std::wstring display_name = monitor_info.szDevice;
        constexpr wchar_t kDevicePrefix[] = L"\\\\.\\";
        if (display_name.rfind(kDevicePrefix, 0) == 0) {
          display_name.erase(0, 4);
        }
        display.name = Utf8FromWide(display_name);
        display.bounds = monitor_info.rcMonitor;
        display.scale = std::max(1.0, static_cast<double>(dpi_x) / 96.0);
        display.primary =
            (monitor_info.dwFlags & MONITORINFOF_PRIMARY) != 0;
        values->push_back(std::move(display));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&displays));

  std::stable_sort(
      displays.begin(), displays.end(),
      [](const DisplayInfo& left, const DisplayInfo& right) {
        return left.primary && !right.primary;
      });
  return displays;
}

const DisplayInfo* FindDisplay(const std::vector<DisplayInfo>& displays,
                               const std::string& id) {
  const auto exact = std::find_if(
      displays.begin(), displays.end(),
      [&id](const DisplayInfo& display) { return display.id == id; });
  if (exact != displays.end()) {
    return &*exact;
  }
  const auto primary = std::find_if(
      displays.begin(), displays.end(),
      [](const DisplayInfo& display) { return display.primary; });
  return primary != displays.end()
             ? &*primary
             : (displays.empty() ? nullptr : &displays.front());
}

const EncodableValue* FindValue(const EncodableMap& map,
                                const char* key) {
  const auto value = map.find(EncodableValue(key));
  return value == map.end() ? nullptr : &value->second;
}

std::string StringValue(const EncodableMap& map, const char* key,
                        const std::string& fallback = {}) {
  const auto* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* string_value = std::get_if<std::string>(value);
  return string_value == nullptr ? fallback : *string_value;
}

double NumberValue(const EncodableMap& map, const char* key,
                   double fallback = 0.0) {
  const auto* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<double>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return static_cast<double>(*number);
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

int64_t IntegerValue(const EncodableMap& map, const char* key,
                     int64_t fallback = 0) {
  const auto* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  return fallback;
}

std::set<std::string> StringSetValue(const EncodableMap& map,
                                     const char* key) {
  std::set<std::string> result;
  const auto* value = FindValue(map, key);
  const auto* list =
      value == nullptr ? nullptr : std::get_if<EncodableList>(value);
  if (list == nullptr) {
    return result;
  }
  for (const auto& item : *list) {
    if (const auto* string_value = std::get_if<std::string>(&item)) {
      result.insert(*string_value);
    }
  }
  return result;
}

INPUT MouseInput(DWORD flags, LONG data = 0, LONG dx = 0, LONG dy = 0) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = dx;
  input.mi.dy = dy;
  input.mi.mouseData = static_cast<DWORD>(data);
  input.mi.dwFlags = flags;
  return input;
}

DWORD ButtonFlag(const std::string& button, bool key_up) {
  if (button == "right") {
    return key_up ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_RIGHTDOWN;
  }
  if (button == "middle") {
    return key_up ? MOUSEEVENTF_MIDDLEUP : MOUSEEVENTF_MIDDLEDOWN;
  }
  return key_up ? MOUSEEVENTF_LEFTUP : MOUSEEVENTF_LEFTDOWN;
}

INPUT ScanCodeInput(WORD scan_code, bool extended, bool key_up) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = 0;
  input.ki.wScan = scan_code;
  input.ki.dwFlags = KEYEVENTF_SCANCODE;
  if (extended) {
    input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
  }
  if (key_up) {
    input.ki.dwFlags |= KEYEVENTF_KEYUP;
  }
  return input;
}

bool DescriptorForVirtualKey(WORD virtual_key,
                             WindowsHostBridge::KeyDescriptor* result) {
  const UINT scan = MapVirtualKeyW(virtual_key, MAPVK_VK_TO_VSC_EX);
  if (scan == 0) {
    return false;
  }
  result->scan_code = static_cast<WORD>(scan & 0xFF);
  result->extended = (scan & 0xFF00) != 0;
  return true;
}

WORD VirtualKeyForName(const std::string& key) {
  if (key.size() == 4 && key.rfind("Key", 0) == 0 &&
      key[3] >= 'A' && key[3] <= 'Z') {
    return static_cast<WORD>(key[3]);
  }
  if (key.size() == 6 && key.rfind("Digit", 0) == 0 &&
      key[5] >= '0' && key[5] <= '9') {
    return static_cast<WORD>(key[5]);
  }
  static const std::map<std::string, WORD> keys = {
      {"Enter", VK_RETURN},       {"Backspace", VK_BACK},
      {"Delete", VK_DELETE},     {"Tab", VK_TAB},
      {"Escape", VK_ESCAPE},     {"Space", VK_SPACE},
      {"ArrowLeft", VK_LEFT},    {"ArrowRight", VK_RIGHT},
      {"ArrowUp", VK_UP},        {"ArrowDown", VK_DOWN},
      {"Home", VK_HOME},         {"End", VK_END},
      {"PageUp", VK_PRIOR},      {"PageDown", VK_NEXT},
      {"F1", VK_F1},             {"F2", VK_F2},
      {"F3", VK_F3},             {"F4", VK_F4},
      {"F5", VK_F5},             {"F6", VK_F6},
      {"F7", VK_F7},             {"F8", VK_F8},
      {"F9", VK_F9},             {"F10", VK_F10},
      {"F11", VK_F11},           {"F12", VK_F12},
      {"Minus", VK_OEM_MINUS},   {"Equal", VK_OEM_PLUS},
      {"BracketLeft", VK_OEM_4}, {"BracketRight", VK_OEM_6},
      {"Backslash", VK_OEM_5},   {"Semicolon", VK_OEM_1},
      {"Quote", VK_OEM_7},       {"Comma", VK_OEM_COMMA},
      {"Period", VK_OEM_PERIOD}, {"Slash", VK_OEM_2},
      {"Backquote", VK_OEM_3},
  };
  const auto found = keys.find(key);
  return found == keys.end() ? 0 : found->second;
}

bool DescriptorForKey(const std::string& key, int64_t physical_hid_usage,
                      WindowsHostBridge::KeyDescriptor* result) {
  // USB HID keyboard usages are stable across keyboard layouts. Use them when
  // present, and retain the key name as a compatibility fallback for mobile
  // controllers that do not provide a physical usage.
  const uint16_t usage = static_cast<uint16_t>(physical_hid_usage & 0xFFFF);
  static const std::map<uint16_t, WindowsHostBridge::KeyDescriptor> hid = {
      {0x04, {0x1E, false}}, {0x05, {0x30, false}},
      {0x06, {0x2E, false}}, {0x07, {0x20, false}},
      {0x08, {0x12, false}}, {0x09, {0x21, false}},
      {0x0A, {0x22, false}}, {0x0B, {0x23, false}},
      {0x0C, {0x17, false}}, {0x0D, {0x24, false}},
      {0x0E, {0x25, false}}, {0x0F, {0x26, false}},
      {0x10, {0x32, false}}, {0x11, {0x31, false}},
      {0x12, {0x18, false}}, {0x13, {0x19, false}},
      {0x14, {0x10, false}}, {0x15, {0x13, false}},
      {0x16, {0x1F, false}}, {0x17, {0x14, false}},
      {0x18, {0x16, false}}, {0x19, {0x2F, false}},
      {0x1A, {0x11, false}}, {0x1B, {0x2D, false}},
      {0x1C, {0x15, false}}, {0x1D, {0x2C, false}},
      {0x1E, {0x02, false}}, {0x1F, {0x03, false}},
      {0x20, {0x04, false}}, {0x21, {0x05, false}},
      {0x22, {0x06, false}}, {0x23, {0x07, false}},
      {0x24, {0x08, false}}, {0x25, {0x09, false}},
      {0x26, {0x0A, false}}, {0x27, {0x0B, false}},
      {0x28, {0x1C, false}}, {0x29, {0x01, false}},
      {0x2A, {0x0E, false}}, {0x2B, {0x0F, false}},
      {0x2C, {0x39, false}}, {0x2D, {0x0C, false}},
      {0x2E, {0x0D, false}}, {0x2F, {0x1A, false}},
      {0x30, {0x1B, false}}, {0x31, {0x2B, false}},
      {0x33, {0x27, false}}, {0x34, {0x28, false}},
      {0x35, {0x29, false}}, {0x36, {0x33, false}},
      {0x37, {0x34, false}}, {0x38, {0x35, false}},
      {0x3A, {0x3B, false}}, {0x3B, {0x3C, false}},
      {0x3C, {0x3D, false}}, {0x3D, {0x3E, false}},
      {0x3E, {0x3F, false}}, {0x3F, {0x40, false}},
      {0x40, {0x41, false}}, {0x41, {0x42, false}},
      {0x42, {0x43, false}}, {0x43, {0x44, false}},
      {0x44, {0x57, false}}, {0x45, {0x58, false}},
      {0x49, {0x52, true}},  {0x4A, {0x47, true}},
      {0x4B, {0x49, true}},  {0x4C, {0x53, true}},
      {0x4D, {0x4F, true}},  {0x4E, {0x51, true}},
      {0x4F, {0x4D, true}},  {0x50, {0x4B, true}},
      {0x51, {0x50, true}},  {0x52, {0x48, true}},
  };
  if (physical_hid_usage != 0) {
    const auto found = hid.find(usage);
    if (found != hid.end()) {
      *result = found->second;
      return true;
    }
  }
  const WORD virtual_key = VirtualKeyForName(key);
  return virtual_key != 0 && DescriptorForVirtualKey(virtual_key, result);
}

std::set<WORD> ModifierVirtualKeys(const std::set<std::string>& modifiers) {
  std::set<WORD> keys;
  if (modifiers.count("shift") != 0) {
    keys.insert(VK_LSHIFT);
  }
  if (modifiers.count("control") != 0) {
    keys.insert(VK_LCONTROL);
  }
  if (modifiers.count("option") != 0) {
    keys.insert(VK_LMENU);
  }
  if (modifiers.count("command") != 0) {
    keys.insert(VK_LWIN);
  }
  return keys;
}

std::string KeyToken(const std::string& key, int64_t physical_hid_usage) {
  std::ostringstream token;
  token << key << ':' << physical_hid_usage;
  return token.str();
}

}  // namespace

WindowsHostBridge::WindowsHostBridge(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kInputChannel,
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

WindowsHostBridge::~WindowsHostBridge() {
  ReleaseAllInput();
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void WindowsHostBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getHostCapabilities") {
    EncodableMap capabilities;
    capabilities[EncodableValue("protocolVersion")] =
        EncodableValue(kHostProtocolVersion);
    capabilities[EncodableValue("canHostDesktop")] = EncodableValue(true);
    capabilities[EncodableValue("canInjectInput")] = EncodableValue(true);
    capabilities[EncodableValue("canEnumerateDisplays")] =
        EncodableValue(true);
    capabilities[EncodableValue("supportsUnicode")] = EncodableValue(true);
    capabilities[EncodableValue("supportsVirtualDesktop")] =
        EncodableValue(true);
    capabilities[EncodableValue("limitation")] =
        EncodableValue(kUipiLimitation);
    result->Success(EncodableValue(capabilities));
    return;
  }

  if (call.method_name() == "checkInputAccess" ||
      call.method_name() == "requestInputAccess") {
    result->Success(EncodableValue(true));
    return;
  }

  if (call.method_name() == "openInputSettings") {
    result->Success(EncodableValue(false));
    return;
  }

  if (call.method_name() == "listDisplays") {
    EncodableList values;
    for (const auto& display : EnumerateDisplays()) {
      const int pixel_width = display.bounds.right - display.bounds.left;
      const int pixel_height = display.bounds.bottom - display.bounds.top;
      EncodableMap value;
      value[EncodableValue("id")] = EncodableValue(display.id);
      value[EncodableValue("name")] = EncodableValue(display.name);
      value[EncodableValue("width")] = EncodableValue(static_cast<int32_t>(
          std::lround(static_cast<double>(pixel_width) / display.scale)));
      value[EncodableValue("height")] = EncodableValue(static_cast<int32_t>(
          std::lround(static_cast<double>(pixel_height) / display.scale)));
      value[EncodableValue("pixelWidth")] =
          EncodableValue(static_cast<int32_t>(pixel_width));
      value[EncodableValue("pixelHeight")] =
          EncodableValue(static_cast<int32_t>(pixel_height));
      value[EncodableValue("pointPixelScale")] =
          EncodableValue(display.scale);
      value[EncodableValue("isPrimary")] = EncodableValue(display.primary);
      values.push_back(EncodableValue(value));
    }
    result->Success(EncodableValue(values));
    return;
  }

  if (call.method_name() == "releasePointerButtons") {
    ReleaseAllInput();
    result->Success();
    return;
  }

  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "Expected an argument map");
    return;
  }

  std::string error;
  bool success = false;
  if (call.method_name() == "pointer") {
    success = HandlePointer(*arguments, &error);
  } else if (call.method_name() == "keyboard") {
    success = HandleKeyboard(*arguments, &error);
  } else {
    result->NotImplemented();
    return;
  }

  if (!success) {
    result->Error("input_injection_failed", error);
    return;
  }
  result->Success();
}

bool WindowsHostBridge::HandlePointer(const EncodableMap& arguments,
                                      std::string* error) {
  const std::string phase = StringValue(arguments, "phase", "move");
  std::vector<INPUT> inputs;

  if (phase == "scroll") {
    const LONG vertical = static_cast<LONG>(
        std::lround(NumberValue(arguments, "deltaY") * 6.0));
    const LONG horizontal = static_cast<LONG>(
        std::lround(NumberValue(arguments, "deltaX") * 6.0));
    if (vertical != 0) {
      inputs.push_back(MouseInput(MOUSEEVENTF_WHEEL, vertical));
    }
    if (horizontal != 0) {
      inputs.push_back(MouseInput(MOUSEEVENTF_HWHEEL, horizontal));
    }
    return SendInputs(&inputs, error);
  }

  const std::string mode = StringValue(arguments, "mode", "absolute");
  if (mode == "relative") {
    const LONG movement_x =
        static_cast<LONG>(std::lround(NumberValue(arguments, "movementX")));
    const LONG movement_y =
        static_cast<LONG>(std::lround(NumberValue(arguments, "movementY")));
    if (movement_x != 0 || movement_y != 0) {
      inputs.push_back(
          MouseInput(MOUSEEVENTF_MOVE, 0, movement_x, movement_y));
    }
  } else {
    const auto displays = EnumerateDisplays();
    const auto* display =
        FindDisplay(displays, StringValue(arguments, "displayId"));
    if (display == nullptr) {
      *error = "Windows did not report an active display";
      return false;
    }
    const double x =
        std::clamp(NumberValue(arguments, "x"), 0.0, 1.0);
    const double y =
        std::clamp(NumberValue(arguments, "y"), 0.0, 1.0);
    const LONG display_width = display->bounds.right - display->bounds.left;
    const LONG display_height = display->bounds.bottom - display->bounds.top;
    const LONG pixel_x = display->bounds.left +
                         static_cast<LONG>(std::lround(
                             x * static_cast<double>(
                                     std::max<LONG>(1, display_width - 1))));
    const LONG pixel_y = display->bounds.top +
                         static_cast<LONG>(std::lround(
                             y * static_cast<double>(
                                     std::max<LONG>(1, display_height - 1))));

    const LONG virtual_left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const LONG virtual_top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const LONG virtual_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const LONG virtual_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (virtual_width <= 0 || virtual_height <= 0) {
      *error = "Windows virtual desktop geometry is unavailable";
      return false;
    }
    const LONG normalized_x = static_cast<LONG>(std::lround(
        static_cast<double>(pixel_x - virtual_left) * 65535.0 /
        static_cast<double>(std::max<LONG>(1, virtual_width - 1))));
    const LONG normalized_y = static_cast<LONG>(std::lround(
        static_cast<double>(pixel_y - virtual_top) * 65535.0 /
        static_cast<double>(std::max<LONG>(1, virtual_height - 1))));
    inputs.push_back(MouseInput(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                                    MOUSEEVENTF_VIRTUALDESK,
                                0, normalized_x, normalized_y));
  }

  const std::string button = StringValue(arguments, "button", "left");
  bool pressed = false;
  bool released = false;
  if (phase == "down") {
    const int click_count = static_cast<int>(
        std::clamp<int64_t>(IntegerValue(arguments, "clickCount", 1), 1, 2));
    if (click_count == 2) {
      inputs.push_back(MouseInput(ButtonFlag(button, false)));
      inputs.push_back(MouseInput(ButtonFlag(button, true)));
    }
    inputs.push_back(MouseInput(ButtonFlag(button, false)));
    pressed = true;
  } else if (phase == "up") {
    inputs.push_back(MouseInput(ButtonFlag(button, true)));
    released = true;
  }
  if (!SendInputs(&inputs, error)) {
    return false;
  }
  if (pressed) {
    pressed_mouse_buttons_.insert(button);
  } else if (released) {
    pressed_mouse_buttons_.erase(button);
  }
  return true;
}

bool WindowsHostBridge::HandleKeyboard(const EncodableMap& arguments,
                                       std::string* error) {
  const std::string type = StringValue(arguments, "type");
  if (type == "text") {
    const std::string text = StringValue(arguments, "text");
    if (text.empty() || WideFromUtf8(text).size() > 256) {
      *error = "Text must contain between 1 and 256 UTF-16 code units";
      return false;
    }
    return HandleText(text, error);
  }

  const std::string key = StringValue(arguments, "key");
  const std::string phase = StringValue(arguments, "phase", "down");
  const int64_t physical_hid_usage =
      IntegerValue(arguments, "physicalHidUsage");
  const std::string token = KeyToken(key, physical_hid_usage);
  std::vector<INPUT> inputs;

  if (phase == "up") {
    auto pressed = pressed_keys_.find(token);
    KeyDescriptor descriptor;
    if (pressed != pressed_keys_.end()) {
      descriptor = pressed->second;
    } else if (!DescriptorForKey(key, physical_hid_usage, &descriptor)) {
      *error = "Unsupported keyboard key: " + key;
      return false;
    }
    inputs.push_back(
        ScanCodeInput(descriptor.scan_code, descriptor.extended, true));
    if (!SendInputs(&inputs, error)) {
      return false;
    }
    if (pressed != pressed_keys_.end()) {
      pressed_keys_.erase(pressed);
    }
    return SetSyntheticModifiers({}, error);
  }

  if (!SetSyntheticModifiers(
          ModifierVirtualKeys(StringSetValue(arguments, "modifiers")), error)) {
    return false;
  }
  KeyDescriptor descriptor;
  if (!DescriptorForKey(key, physical_hid_usage, &descriptor)) {
    SetSyntheticModifiers({}, nullptr);
    *error = "Unsupported keyboard key: " + key;
    return false;
  }
  inputs.push_back(
      ScanCodeInput(descriptor.scan_code, descriptor.extended, false));
  if (!SendInputs(&inputs, error)) {
    SetSyntheticModifiers({}, nullptr);
    return false;
  }
  pressed_keys_[token] = descriptor;
  return true;
}

bool WindowsHostBridge::HandleText(const std::string& text,
                                   std::string* error) {
  const std::wstring utf16 = WideFromUtf8(text);
  if (utf16.empty()) {
    *error = "Text is not valid UTF-8";
    return false;
  }
  std::vector<INPUT> inputs;
  inputs.reserve(utf16.size() * 2);
  for (const wchar_t code_unit : utf16) {
    INPUT down{};
    down.type = INPUT_KEYBOARD;
    down.ki.wVk = 0;
    down.ki.wScan = static_cast<WORD>(code_unit);
    down.ki.dwFlags = KEYEVENTF_UNICODE;
    inputs.push_back(down);
    INPUT up = down;
    up.ki.dwFlags |= KEYEVENTF_KEYUP;
    inputs.push_back(up);
  }
  return SendInputs(&inputs, error);
}

bool WindowsHostBridge::SetSyntheticModifiers(
    const std::set<WORD>& requested, std::string* error) {
  std::vector<INPUT> inputs;
  for (const WORD modifier : pressed_modifiers_) {
    if (requested.count(modifier) == 0) {
      KeyDescriptor descriptor;
      if (DescriptorForVirtualKey(modifier, &descriptor)) {
        inputs.push_back(
            ScanCodeInput(descriptor.scan_code, descriptor.extended, true));
      }
    }
  }
  for (const WORD modifier : requested) {
    if (pressed_modifiers_.count(modifier) == 0) {
      KeyDescriptor descriptor;
      if (DescriptorForVirtualKey(modifier, &descriptor)) {
        inputs.push_back(
            ScanCodeInput(descriptor.scan_code, descriptor.extended, false));
      }
    }
  }
  if (!SendInputs(&inputs, error)) {
    return false;
  }
  pressed_modifiers_ = requested;
  return true;
}

bool WindowsHostBridge::SendInputs(std::vector<INPUT>* inputs,
                                   std::string* error) {
  if (inputs == nullptr || inputs->empty()) {
    return true;
  }
  SetLastError(ERROR_SUCCESS);
  const UINT sent = SendInput(static_cast<UINT>(inputs->size()), inputs->data(),
                              sizeof(INPUT));
  if (sent == inputs->size()) {
    return true;
  }
  if (error != nullptr) {
    const DWORD native_error = GetLastError();
    std::ostringstream message;
    message << "SendInput inserted " << sent << " of " << inputs->size()
            << " events (Win32 " << native_error
            << "). The target may have higher integrity or be a UAC desktop.";
    *error = message.str();
  }
  return false;
}

void WindowsHostBridge::ReleaseAllInput() {
  std::vector<INPUT> inputs;
  for (const auto& key : pressed_keys_) {
    inputs.push_back(ScanCodeInput(key.second.scan_code, key.second.extended,
                                   true));
  }
  for (const WORD modifier : pressed_modifiers_) {
    KeyDescriptor descriptor;
    if (DescriptorForVirtualKey(modifier, &descriptor)) {
      inputs.push_back(
          ScanCodeInput(descriptor.scan_code, descriptor.extended, true));
    }
  }
  for (const auto& button : pressed_mouse_buttons_) {
    inputs.push_back(MouseInput(ButtonFlag(button, true)));
  }
  std::string ignored;
  SendInputs(&inputs, &ignored);
  pressed_keys_.clear();
  pressed_modifiers_.clear();
  pressed_mouse_buttons_.clear();
}
