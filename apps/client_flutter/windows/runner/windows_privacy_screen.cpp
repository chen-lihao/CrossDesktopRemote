#include "windows_privacy_screen.h"

#include <dwmapi.h>

#include <algorithm>

namespace {

constexpr wchar_t kPrivacyWindowClass[] =
    L"CrossDesktopRemotePrivacyScreenWindow";
constexpr DWORD kOverlayStyles = WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
    WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT;

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

bool IsInputTransparent(HWND window) {
  const auto styles = GetWindowLongPtrW(window, GWL_EXSTYLE);
  BYTE alpha = 0;
  DWORD flags = 0;
  return (styles & kOverlayStyles) == kOverlayStyles &&
         GetLayeredWindowAttributes(window, nullptr, &alpha, &flags) &&
         (flags & LWA_ALPHA) != 0 && alpha == 255;
}

bool IsCaptureExcluded(HWND window) {
  DWORD affinity = WDA_NONE;
  return GetWindowDisplayAffinity(window, &affinity) &&
         affinity == WDA_EXCLUDEFROMCAPTURE;
}

void DestroyWindows(std::vector<HWND>* windows) {
  for (HWND window : *windows) {
    if (IsWindow(window)) DestroyWindow(window);
  }
  windows->clear();
}

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
      // Supplemental only: HTTRANSPARENT alone works within the same thread.
      // Cross-thread/process click-through is provided by LAYERED+TRANSPARENT.
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
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
  Rebuild();
  return GetStatus();
}

void WindowsPrivacyScreen::Deactivate() {
  active_ = false;
  DestroyWindows(&windows_);
  failure_reason_.clear();
}

void WindowsPrivacyScreen::Refresh() {
  if (active_) Rebuild();
}

WindowsPrivacyScreen::Status WindowsPrivacyScreen::GetStatus() const {
  Status status;
  const auto bounds = MonitorBounds();
  status.expected_display_count = static_cast<int>(bounds.size());
  status.capture_excluded = !windows_.empty();
  status.input_transparent = !windows_.empty();
  std::vector<bool> covered(bounds.size(), false);
  for (HWND window : windows_) {
    status.capture_excluded &= IsWindow(window) && IsCaptureExcluded(window);
    status.input_transparent &= IsWindow(window) && IsInputTransparent(window);
    RECT rect{};
    if (!IsWindowVisible(window) || !GetWindowRect(window, &rect)) continue;
    for (size_t i = 0; i < bounds.size(); ++i) {
      if (!covered[i] && EqualRect(&rect, &bounds[i])) {
        covered[i] = true;
        ++status.covered_display_count;
        break;
      }
    }
  }
  status.failure_reason = failure_reason_;
  if (!active_ && windows_.empty()) {
    status.phase = "inactive";
  } else if (failure_reason_.empty() && status.capture_excluded &&
             status.input_transparent && AvailabilityFailure().empty() &&
             status.expected_display_count > 0 &&
             status.covered_display_count == status.expected_display_count) {
    status.phase = "active";
  } else {
    status.phase = "failed";
    if (status.failure_reason.empty()) {
      status.failure_reason = "隐私屏覆盖、点击穿透或采集排除校验失败";
    }
  }
  return status;
}

int WindowsPrivacyScreen::DisplayCount() const {
  return static_cast<int>(MonitorBounds().size());
}

std::string WindowsPrivacyScreen::AvailabilityFailure() {
  // The runner manifest declares Windows 10 compatibility. Older versions
  // accept EXCLUDEFROMCAPTURE but interpret it as MONITOR (a captured black
  // rectangle), which cannot support our visual-overlay capture contract.
  OSVERSIONINFOEXW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  version.dwMajorVersion = 10;
  version.dwBuildNumber = 19041;
  DWORDLONG conditions = 0;
  conditions = VerSetConditionMask(conditions, VER_MAJORVERSION, VER_GREATER_EQUAL);
  conditions = VerSetConditionMask(conditions, VER_MINORVERSION, VER_GREATER_EQUAL);
  conditions = VerSetConditionMask(conditions, VER_BUILDNUMBER, VER_GREATER_EQUAL);
  if (!VerifyVersionInfoW(&version,
                         VER_MAJORVERSION | VER_MINORVERSION | VER_BUILDNUMBER,
                         conditions)) {
    return "标准隐私屏需要 Windows 10 2004 或更高版本";
  }
  BOOL composition = FALSE;
  if (FAILED(DwmIsCompositionEnabled(&composition)) || !composition) {
    return "标准隐私屏需要桌面窗口合成器";
  }
  return {};
}

HWND WindowsPrivacyScreen::InputTargetAtPoint(const POINT& point) const {
  HWND target = WindowFromPoint(point);
  if (target == nullptr) return nullptr;
  target = GetAncestor(target, GA_ROOT);
  const auto is_overlay = [this](HWND window) {
    return std::find(windows_.begin(), windows_.end(), window) != windows_.end();
  };
  if (!is_overlay(target)) return target;
  // Some window lookup paths report the visible overlay even though USER32
  // routes actual input through it. Exclude only our registered HWNDs, never
  // identify another application's window by class name or send it messages.
  struct Query {
    POINT point;
    HWND overlay;
    const std::vector<HWND>* overlays;
    HWND result = nullptr;
    bool below_overlay = false;
  } lookup{point, target, &windows_};
  // EnumWindows provides bounded enumeration when foreign windows disappear;
  // walking GW_HWNDNEXT during destruction can revisit recycled HWNDs.
  EnumWindows([](HWND candidate, LPARAM context) -> BOOL {
    auto& query = *reinterpret_cast<Query*>(context);
    if (candidate == query.overlay) query.below_overlay = true;
    const auto& overlays = *query.overlays;
    RECT rect{};
    DWORD cloaked = 0;
    if (!query.below_overlay ||
        std::find(overlays.begin(), overlays.end(), candidate) != overlays.end() ||
        !IsWindowVisible(candidate) || IsIconic(candidate) ||
        !IsWindowEnabled(candidate) || !GetWindowRect(candidate, &rect) ||
        !PtInRect(&rect, query.point)) return TRUE;
    if (SUCCEEDED(DwmGetWindowAttribute(candidate, DWMWA_CLOAKED, &cloaked,
                                       sizeof(cloaked))) && cloaked) return TRUE;
    const auto styles = GetWindowLongPtrW(candidate, GWL_EXSTYLE);
    if ((styles & (WS_EX_LAYERED | WS_EX_TRANSPARENT)) ==
        (WS_EX_LAYERED | WS_EX_TRANSPARENT)) return TRUE;
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    if (region == nullptr) return FALSE;
    const int region_type = GetWindowRgn(candidate, region);
    const bool contains = region_type == ERROR ||
        PtInRegion(region, query.point.x - rect.left, query.point.y - rect.top);
    DeleteObject(region);
    if (!contains) return TRUE;
    query.result = candidate;
    return FALSE;
  }, reinterpret_cast<LPARAM>(&lookup));
  return lookup.result;
}

bool WindowsPrivacyScreen::Rebuild() {
  failure_reason_ = AvailabilityFailure();
  if (!failure_reason_.empty()) return false;

  if (!EnsureWindowClass()) {
    failure_reason_ = "无法注册隐私屏窗口";
    return false;
  }
  const auto bounds = MonitorBounds();
  if (bounds.empty()) {
    failure_reason_ = "没有可覆盖的活动显示器";
    return false;
  }

  std::vector<HWND> pending;
  const auto fail = [this, &pending](const char* reason) {
    failure_reason_ = reason;
    DestroyWindows(&pending);
    return false;
  };
  // Prepare and verify every hidden window before changing current coverage.
  for (const RECT& rect : bounds) {
    auto* label = new std::wstring(controller_label_);
    HWND window = CreateWindowExW(
        kOverlayStyles,
        kPrivacyWindowClass, L"CrossDesktopRemote Privacy Screen", WS_POPUP,
        rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
        nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (window == nullptr) {
      delete label;
      return fail("无法创建隐私屏窗口");
    }
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(label));
    pending.push_back(window);
    if (!SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA) ||
        !IsInputTransparent(window)) {
      return fail("无法建立不拦截输入的隐私屏窗口");
    }
    if (!SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE) ||
        !IsCaptureExcluded(window)) {
      return fail("系统不支持从屏幕采集中排除隐私屏窗口");
    }
  }
  for (size_t i = 0; i < pending.size(); ++i) {
    const RECT& rect = bounds[i];
    HWND window = pending[i];
    RECT actual{};
    if (!SetWindowPos(window, HWND_TOPMOST, rect.left, rect.top,
                      rect.right - rect.left, rect.bottom - rect.top,
                      SWP_NOACTIVATE | SWP_SHOWWINDOW) ||
        !IsWindowVisible(window) || !GetWindowRect(window, &actual) ||
        !EqualRect(&rect, &actual)) {
      return fail("无法完整显示隐私屏窗口");
    }
    RedrawWindow(window, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  }
  // Commit new coverage before retiring old windows (including hot-plug).
  windows_.swap(pending);
  DestroyWindows(&pending);
  return true;
}
