#include "windows_privacy_screen.h"

#include <algorithm>

namespace {

constexpr wchar_t kPrivacyWindowClass[] =
    L"CrossDesktopRemotePrivacyScreenWindow";

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) return L"远程设备";
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) return L"远程设备";
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  if (result.size() > 80) result.resize(80);
  return result;
}

LRESULT CALLBACK PrivacyWindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT bounds{};
      GetClientRect(window, &bounds);
      HBRUSH background = CreateSolidBrush(RGB(9, 10, 18));
      FillRect(dc, &bounds, background);
      DeleteObject(background);
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(246, 247, 255));
      HFONT title_font = CreateFontW(
          -34, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
          CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
      HFONT previous_font =
          static_cast<HFONT>(SelectObject(dc, title_font));
      RECT title = bounds;
      title.top = bounds.top + (bounds.bottom - bounds.top) / 2 - 70;
      title.bottom = title.top + 50;
      DrawTextW(dc, L"此电脑正在接受远程协助", -1, &title,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      SelectObject(dc, previous_font);
      DeleteObject(title_font);

      SetTextColor(dc, RGB(192, 196, 214));
      HFONT detail_font = CreateFontW(
          -20, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
          CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
      previous_font = static_cast<HFONT>(SelectObject(dc, detail_font));
      auto* label = reinterpret_cast<std::wstring*>(
          GetWindowLongPtrW(window, GWLP_USERDATA));
      std::wstring detail = L"连接设备：";
      detail += label == nullptr ? L"远程设备" : *label;
      detail += L"\n如非本人操作，请按 Ctrl+Alt+Delete 结束应用或注销";
      RECT detail_bounds = bounds;
      detail_bounds.top = title.bottom + 12;
      detail_bounds.bottom = detail_bounds.top + 70;
      DrawTextW(dc, detail.c_str(), -1, &detail_bounds,
                DT_CENTER | DT_TOP | DT_WORDBREAK);
      SelectObject(dc, previous_font);
      DeleteObject(detail_font);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_DESTROY: {
      auto* label = reinterpret_cast<std::wstring*>(
          GetWindowLongPtrW(window, GWLP_USERDATA));
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      delete label;
      return 0;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

bool EnsureWindowClass() {
  static const bool registered = [] {
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = PrivacyWindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kPrivacyWindowClass;
    window_class.hbrBackground = nullptr;
    if (RegisterClassExW(&window_class) != 0) return true;
    return GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }();
  return registered;
}

std::vector<RECT> MonitorBounds() {
  std::vector<RECT> bounds;
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM context) -> BOOL {
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        if (GetMonitorInfoW(monitor, &info)) {
          reinterpret_cast<std::vector<RECT>*>(context)->push_back(
              info.rcMonitor);
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&bounds));
  return bounds;
}

}  // namespace

WindowsPrivacyScreen::WindowsPrivacyScreen() = default;

WindowsPrivacyScreen::~WindowsPrivacyScreen() {
  Deactivate();
}

WindowsPrivacyScreen::Status WindowsPrivacyScreen::Activate(
    const std::string& controller_label) {
  controller_label_ = WideFromUtf8(controller_label);
  active_ = true;
  failure_reason_.clear();
  if (!Rebuild()) Deactivate();
  return GetStatus();
}

void WindowsPrivacyScreen::Deactivate() {
  active_ = false;
  for (HWND window : windows_) {
    if (IsWindow(window)) DestroyWindow(window);
  }
  windows_.clear();
  capture_excluded_ = false;
}

void WindowsPrivacyScreen::Refresh() {
  if (active_) Rebuild();
}

WindowsPrivacyScreen::Status WindowsPrivacyScreen::GetStatus() const {
  Status status;
  status.expected_display_count = DisplayCount();
  status.covered_display_count = static_cast<int>(std::count_if(
      windows_.begin(), windows_.end(), [](HWND window) {
        return IsWindow(window) && IsWindowVisible(window);
      }));
  status.capture_excluded = capture_excluded_;
  status.failure_reason = failure_reason_;
  if (!active_ && windows_.empty()) {
    status.phase = "inactive";
  } else if (failure_reason_.empty() && capture_excluded_ &&
             status.expected_display_count > 0 &&
             status.covered_display_count == status.expected_display_count) {
    status.phase = "active";
  } else {
    status.phase = "failed";
  }
  return status;
}

int WindowsPrivacyScreen::DisplayCount() const {
  return static_cast<int>(MonitorBounds().size());
}

bool WindowsPrivacyScreen::Rebuild() {
  for (HWND window : windows_) {
    if (IsWindow(window)) DestroyWindow(window);
  }
  windows_.clear();
  capture_excluded_ = false;
  failure_reason_.clear();

  if (!EnsureWindowClass()) {
    failure_reason_ = "无法注册隐私屏窗口";
    return false;
  }
  const auto bounds = MonitorBounds();
  if (bounds.empty()) {
    failure_reason_ = "没有可覆盖的活动显示器";
    return false;
  }

  for (const RECT& rect : bounds) {
    auto* label = new std::wstring(controller_label_);
    HWND window = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
            WS_EX_TRANSPARENT,
        kPrivacyWindowClass, L"CrossDesktopRemote Privacy Screen", WS_POPUP,
        rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
        nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (window == nullptr) {
      delete label;
      failure_reason_ = "无法创建隐私屏窗口";
      return false;
    }
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(label));
    BOOL excluded = SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
    if (!excluded) {
      excluded = SetWindowDisplayAffinity(window, WDA_MONITOR);
    }
    if (!excluded) {
      DestroyWindow(window);
      failure_reason_ = "系统不支持从屏幕采集中排除隐私屏窗口";
      return false;
    }
    SetWindowPos(window, HWND_TOPMOST, rect.left, rect.top,
                 rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    RedrawWindow(window, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    windows_.push_back(window);
  }
  capture_excluded_ = windows_.size() == bounds.size();
  return capture_excluded_;
}
