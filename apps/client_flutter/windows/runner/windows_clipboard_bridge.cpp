#include "windows_clipboard_bridge.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <shellapi.h>
#include <shlobj.h>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kMethodChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/clipboard";
constexpr char kEventChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/clipboard_events";
constexpr size_t kMaximumTextBytes = 256 * 1024;
constexpr size_t kMaximumClipboardFiles = 1024;

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

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

}  // namespace

WindowsClipboardBridge::WindowsClipboardBridge(
    flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kMethodChannel,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<FlutterResult> result) {
        HandleMethodCall(call, std::move(result));
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
  AddClipboardFormatListener(window_);
}

WindowsClipboardBridge::~WindowsClipboardBridge() {
  RemoveClipboardFormatListener(window_);
  event_channel_->SetStreamHandler(nullptr);
  method_channel_->SetMethodCallHandler(nullptr);
}

bool WindowsClipboardBridge::HandleWindowMessage(UINT message) {
  if (message == WM_CLIPBOARDUPDATE) {
    EmitSnapshot();
  }
  return false;
}

void WindowsClipboardBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<FlutterResult> result) {
  if (call.method_name() == "getSnapshot") {
    result->Success(Snapshot());
    return;
  }
  if (call.method_name() != "writeText" &&
      call.method_name() != "writeFiles") {
    result->NotImplemented();
    return;
  }
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_clipboard_text", "Expected an argument map");
    return;
  }
  if (call.method_name() == "writeFiles") {
    const auto entry = arguments->find(EncodableValue("paths"));
    const auto* encoded_paths =
        entry == arguments->end()
            ? nullptr
            : std::get_if<flutter::EncodableList>(&entry->second);
    if (encoded_paths == nullptr || encoded_paths->empty() ||
        encoded_paths->size() > kMaximumClipboardFiles) {
      result->Error("invalid_clipboard_files",
                    "Expected 1-1024 UTF-8 file paths");
      return;
    }
    std::vector<std::wstring> paths;
    for (const auto& encoded : *encoded_paths) {
      const auto* utf8_path = std::get_if<std::string>(&encoded);
      const std::wstring path =
          utf8_path == nullptr ? std::wstring() : WideFromUtf8(*utf8_path);
      if (path.empty() ||
          GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        result->Error("invalid_clipboard_files",
                      "A clipboard file no longer exists");
        return;
      }
      paths.push_back(path);
    }
    HGLOBAL file_drop = BuildFileDrop(paths);
    HGLOBAL preferred_effect = BuildPreferredDropEffect();
    if (file_drop == nullptr || preferred_effect == nullptr) {
      if (file_drop != nullptr) GlobalFree(file_drop);
      if (preferred_effect != nullptr) GlobalFree(preferred_effect);
      result->Error("clipboard_write_failed",
                    "Unable to allocate Windows file clipboard data");
      return;
    }
    if (!OpenClipboardWithRetry()) {
      GlobalFree(file_drop);
      GlobalFree(preferred_effect);
      result->Error("clipboard_busy", "The Windows clipboard is busy");
      return;
    }
    if (!EmptyClipboard()) {
      GlobalFree(file_drop);
      GlobalFree(preferred_effect);
      CloseClipboard();
      result->Error("clipboard_write_failed",
                    "Unable to take ownership of the Windows clipboard");
      return;
    }
    const UINT preferred_effect_format =
        RegisterClipboardFormat(CFSTR_PREFERREDDROPEFFECT);
    if (preferred_effect_format == 0 ||
        SetClipboardData(preferred_effect_format, preferred_effect) == nullptr) {
      GlobalFree(file_drop);
      GlobalFree(preferred_effect);
      CloseClipboard();
      result->Error("clipboard_write_failed",
                    "Unable to publish the preferred file copy operation");
      return;
    }
    preferred_effect = nullptr;
    if (SetClipboardData(CF_HDROP, file_drop) == nullptr) {
      GlobalFree(file_drop);
      CloseClipboard();
      result->Error("clipboard_write_failed",
                    "Unable to publish Windows file paths");
      return;
    }
    file_drop = nullptr;
    CloseClipboard();
    if (!VerifyFileDrop(paths)) {
      result->Error("clipboard_write_failed",
                    "Windows did not commit the materialized file clipboard");
      return;
    }
    result->Success(FileSnapshot(paths, "materialized-cf-hdrop"));
    return;
  }
  const auto entry = arguments->find(EncodableValue("text"));
  const auto* text = entry == arguments->end()
                         ? nullptr
                         : std::get_if<std::string>(&entry->second);
  if (text == nullptr) {
    result->Error("invalid_clipboard_text", "Expected UTF-8 text");
    return;
  }
  if (text->size() > kMaximumTextBytes) {
    result->Error("clipboard_text_too_large",
                  "Clipboard text exceeds 256 KiB");
    return;
  }
  const std::wstring wide = WideFromUtf8(*text);
  if (!text->empty() && wide.empty()) {
    result->Error("invalid_clipboard_text", "Text is not valid UTF-8");
    return;
  }
  if (!OpenClipboardWithRetry()) {
    result->Error("clipboard_busy", "The Windows clipboard is busy");
    return;
  }
  EmptyClipboard();
  const size_t allocation_size = (wide.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, allocation_size);
  if (memory == nullptr) {
    CloseClipboard();
    result->Error("clipboard_write_failed", "Unable to allocate clipboard data");
    return;
  }
  auto* destination = static_cast<wchar_t*>(GlobalLock(memory));
  if (destination == nullptr) {
    GlobalFree(memory);
    CloseClipboard();
    result->Error("clipboard_write_failed", "Unable to lock clipboard data");
    return;
  }
  std::memcpy(destination, wide.c_str(), allocation_size);
  GlobalUnlock(memory);
  if (SetClipboardData(CF_UNICODETEXT, memory) == nullptr) {
    GlobalFree(memory);
    CloseClipboard();
    result->Error("clipboard_write_failed",
                  "Unable to write the Windows clipboard");
    return;
  }
  CloseClipboard();
  result->Success(Snapshot());
}

EncodableValue WindowsClipboardBridge::Snapshot() {
  const int64_t revision =
      static_cast<int64_t>(GetClipboardSequenceNumber());
  if (IsClipboardFormatAvailable(CF_HDROP) && OpenClipboardWithRetry()) {
    const HDROP drop = reinterpret_cast<HDROP>(GetClipboardData(CF_HDROP));
    flutter::EncodableList paths;
    if (drop != nullptr) {
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT index = 0; index < count && index < kMaximumClipboardFiles;
           ++index) {
        const UINT length = DragQueryFileW(drop, index, nullptr, 0);
        std::wstring path(static_cast<size_t>(length) + 1, L'\0');
        if (DragQueryFileW(drop, index, path.data(), length + 1) > 0) {
          path.resize(length);
          paths.emplace_back(Utf8FromWide(path));
        }
      }
    }
    CloseClipboard();
    if (!paths.empty()) {
      return EncodableValue(EncodableMap{
          {EncodableValue("revision"), EncodableValue(revision)},
          {EncodableValue("hasText"), EncodableValue(false)},
          {EncodableValue("tooLarge"), EncodableValue(false)},
          {EncodableValue("utf8Bytes"), EncodableValue(int32_t{0})},
          {EncodableValue("filePaths"), EncodableValue(paths)},
      });
    }
  }
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT) ||
      !OpenClipboardWithRetry()) {
    return EncodableValue(EncodableMap{
        {EncodableValue("revision"), EncodableValue(revision)},
        {EncodableValue("hasText"), EncodableValue(false)},
        {EncodableValue("tooLarge"), EncodableValue(false)},
        {EncodableValue("utf8Bytes"), EncodableValue(int32_t{0})},
    });
  }
  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  const auto* pointer = handle == nullptr
                            ? nullptr
                            : static_cast<const wchar_t*>(GlobalLock(handle));
  const std::wstring wide = pointer == nullptr ? L"" : std::wstring(pointer);
  if (pointer != nullptr) GlobalUnlock(handle);
  CloseClipboard();
  const std::string text = Utf8FromWide(wide);
  const bool too_large = text.size() > kMaximumTextBytes;
  EncodableMap value{
      {EncodableValue("revision"), EncodableValue(revision)},
      {EncodableValue("hasText"), EncodableValue(true)},
      {EncodableValue("tooLarge"), EncodableValue(too_large)},
      {EncodableValue("utf8Bytes"),
       EncodableValue(static_cast<int64_t>(text.size()))},
  };
  if (!too_large) {
    value[EncodableValue("text")] = EncodableValue(text);
  }
  return EncodableValue(value);
}

EncodableValue WindowsClipboardBridge::FileSnapshot(
    const std::vector<std::wstring>& paths, const char* delivery) {
  flutter::EncodableList encoded_paths;
  for (const auto& path : paths) {
    encoded_paths.emplace_back(Utf8FromWide(path));
  }
  return EncodableValue(EncodableMap{
      {EncodableValue("revision"),
       EncodableValue(static_cast<int64_t>(GetClipboardSequenceNumber()))},
      {EncodableValue("hasText"), EncodableValue(false)},
      {EncodableValue("tooLarge"), EncodableValue(false)},
      {EncodableValue("utf8Bytes"), EncodableValue(int32_t{0})},
      {EncodableValue("filePaths"), EncodableValue(encoded_paths)},
      {EncodableValue("fileDelivery"), EncodableValue(std::string(delivery))},
  });
}

HGLOBAL WindowsClipboardBridge::BuildFileDrop(
    const std::vector<std::wstring>& paths) {
  size_t characters = 1;
  for (const auto& path : paths) characters += path.size() + 1;
  const size_t allocation_size =
      sizeof(DROPFILES) + characters * sizeof(wchar_t);
  HGLOBAL memory =
      GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, allocation_size);
  if (memory == nullptr) return nullptr;
  auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
  if (drop == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  drop->pFiles = static_cast<DWORD>(sizeof(DROPFILES));
  drop->fWide = TRUE;
  auto* destination = reinterpret_cast<wchar_t*>(
      reinterpret_cast<BYTE*>(drop) + sizeof(DROPFILES));
  for (const auto& path : paths) {
    std::memcpy(destination, path.c_str(),
                (path.size() + 1) * sizeof(wchar_t));
    destination += path.size() + 1;
  }
  *destination = L'\0';
  GlobalUnlock(memory);
  return memory;
}

HGLOBAL WindowsClipboardBridge::BuildPreferredDropEffect() {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (memory == nullptr) return nullptr;
  auto* effect = static_cast<DWORD*>(GlobalLock(memory));
  if (effect == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  *effect = DROPEFFECT_COPY;
  GlobalUnlock(memory);
  return memory;
}

bool WindowsClipboardBridge::VerifyFileDrop(
    const std::vector<std::wstring>& paths) {
  if (!OpenClipboardWithRetry()) return false;
  const HDROP drop = reinterpret_cast<HDROP>(GetClipboardData(CF_HDROP));
  bool matches = drop != nullptr &&
                 DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0) ==
                     static_cast<UINT>(paths.size());
  for (UINT index = 0;
       matches && index < static_cast<UINT>(paths.size()); ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring actual(static_cast<size_t>(length) + 1, L'\0');
    if (DragQueryFileW(drop, index, actual.data(), length + 1) == 0) {
      matches = false;
      break;
    }
    actual.resize(length);
    matches = CompareStringOrdinal(actual.c_str(), -1,
                                   paths[index].c_str(), -1, TRUE) ==
              CSTR_EQUAL;
  }
  CloseClipboard();
  return matches;
}

bool WindowsClipboardBridge::OpenClipboardWithRetry() {
  for (int attempt = 0; attempt < 8; ++attempt) {
    if (OpenClipboard(window_)) return true;
    Sleep(4);
  }
  return false;
}

void WindowsClipboardBridge::EmitSnapshot() {
  if (event_sink_) event_sink_->Success(Snapshot());
}
