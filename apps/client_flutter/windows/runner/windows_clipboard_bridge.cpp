#include "windows_clipboard_bridge.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kMethodChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/clipboard";
constexpr char kEventChannel[] =
    "com.crossdesktopremote.cross_desktop_remote/clipboard_events";
constexpr size_t kMaximumTextBytes = 256 * 1024;

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
  if (message != WM_CLIPBOARDUPDATE) return false;
  EmitSnapshot();
  return false;
}

void WindowsClipboardBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<FlutterResult> result) {
  if (call.method_name() == "getSnapshot") {
    result->Success(Snapshot());
    return;
  }
  if (call.method_name() != "writeText") {
    result->NotImplemented();
    return;
  }
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_clipboard_text", "Expected an argument map");
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

bool WindowsClipboardBridge::OpenClipboardWithRetry() {
  for (int attempt = 0; attempt < 4; ++attempt) {
    if (OpenClipboard(window_)) return true;
    Sleep(2);
  }
  return false;
}

void WindowsClipboardBridge::EmitSnapshot() {
  if (event_sink_) event_sink_->Success(Snapshot());
}
