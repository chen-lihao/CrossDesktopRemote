#include "windows_privacy_screen.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cwchar>
#include <future>
#include <stdexcept>
#include <thread>

namespace {

std::atomic<int> left_downs{0};
std::atomic<int> left_ups{0};
std::atomic<int> right_ups{0};
std::atomic<int> wheels{0};

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

LRESULT CALLBACK ReceiverProc(HWND window, UINT message, WPARAM wparam,
                               LPARAM lparam) {
  switch (message) {
    case WM_LBUTTONDOWN: ++left_downs; return 0;
    case WM_LBUTTONUP: ++left_ups; return 0;
    case WM_RBUTTONUP: ++right_ups; return 0;
    case WM_MOUSEWHEEL: ++wheels; return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

// A separate UI thread is essential: HTTRANSPARENT alone can pass clicks
// between same-thread windows and would hide the original regression.
class Receiver {
 public:
  Receiver() {
    std::promise<HWND> ready;
    auto future = ready.get_future();
    thread_ = std::thread([ready = std::move(ready)]() mutable {
      WNDCLASSW type{};
      type.lpfnWndProc = ReceiverProc;
      type.hInstance = GetModuleHandleW(nullptr);
      type.lpszClassName = L"CdrPrivacyTestReceiver";
      RegisterClassW(&type);
      HWND receiver_window = CreateWindowExW(
          WS_EX_TOPMOST, type.lpszClassName, L"Privacy click test receiver",
          WS_OVERLAPPEDWINDOW, 60, 60, 500, 300, nullptr, nullptr,
          type.hInstance, nullptr);
      if (receiver_window != nullptr) ShowWindow(receiver_window, SW_SHOW);
      ready.set_value(receiver_window);
      if (receiver_window == nullptr) return;
      MSG message{};
      while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
    });
    window = future.get();
  }

  ~Receiver() {
    if (window != nullptr) PostMessageW(window, WM_CLOSE, 0, 0);
    if (thread_.joinable()) thread_.join();
  }

  HWND window = nullptr;

 private:
  std::thread thread_;
};

template <typename Predicate>
bool PumpUntil(Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(3);
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (predicate()) return true;
    Sleep(5);
  } while (std::chrono::steady_clock::now() < deadline);
  return false;
}

std::vector<HWND> Overlays() {
  std::vector<HWND> windows;
  EnumThreadWindows(GetCurrentThreadId(),
      [](HWND window, LPARAM context) -> BOOL {
        wchar_t name[128]{};
        GetClassNameW(window, name, 128);
        if (wcscmp(name, L"CrossDesktopRemotePrivacyScreenWindow") == 0) {
          reinterpret_cast<std::vector<HWND>*>(context)->push_back(window);
        }
        return TRUE;
      }, reinterpret_cast<LPARAM>(&windows));
  return windows;
}

void Click(const POINT& point, DWORD down, DWORD up) {
  Check(SetCursorPos(point.x, point.y) != FALSE, "cannot position test cursor");
  INPUT inputs[2]{};
  inputs[0].type = inputs[1].type = INPUT_MOUSE;
  inputs[0].mi.dwFlags = down;
  inputs[1].mi.dwFlags = up;
  Check(SendInput(2, inputs, sizeof(INPUT)) == 2, "SendInput failed");
}

void Run() {
  Check(WindowsPrivacyScreen::AvailabilityFailure().empty(),
        "requires Windows 10 build 19041+ with DWM and an unlocked desktop");
  Receiver receiver;
  Check(receiver.window != nullptr, "cannot create test receiver");
  Check(SetForegroundWindow(receiver.window) != FALSE, "cannot focus receiver");
  POINT content{80, 80};
  Check(ClientToScreen(receiver.window, &content) != FALSE, "cannot resolve point");
  WindowsPrivacyScreen privacy;
  for (int cycle = 0; cycle < 30; ++cycle) {
    const auto status = privacy.Activate("Regression test");
    Check(status.phase == "active" && status.capture_excluded &&
          status.input_transparent, "overlay contract not satisfied");
    Check(static_cast<int>(Overlays().size()) == status.expected_display_count,
          "overlay count mismatch");
    Check(privacy.InputTargetAtPoint(content) == receiver.window,
          "overlay obscures underlying input target");
    Check(GetForegroundWindow() == receiver.window, "overlay steals activation");
    const int clicks = left_ups.load();
    Click(content, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    Check(PumpUntil([clicks] { return left_ups.load() == clicks + 1; }),
          "click failed to reach a different UI thread through privacy screen");
    Check(left_downs.load() == left_ups.load(), "unbalanced mouse buttons");
    privacy.Refresh();
    Check(privacy.GetStatus().phase == "active", "rebuild failed");
    Check(Overlays().size() == static_cast<size_t>(status.expected_display_count),
          "rebuild leaked windows");
    privacy.Deactivate();
    Check(privacy.GetStatus().phase == "inactive" && Overlays().empty(),
          "deactivation leaked windows");
  }

  privacy.Activate("Right click and scroll");
  Click(content, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
  Check(PumpUntil([] { return right_ups.load() == 1; }), "right click blocked");
  INPUT scroll{};
  scroll.type = INPUT_MOUSE;
  scroll.mi.dwFlags = MOUSEEVENTF_WHEEL;
  scroll.mi.mouseData = WHEEL_DELTA;
  Check(SendInput(1, &scroll, sizeof(INPUT)) == 1, "cannot inject scroll");
  Check(PumpUntil([] { return wheels.load() == 1; }), "scroll blocked");

  auto windows = Overlays();
  Check(!windows.empty(), "missing overlays");
  const LONG_PTR styles = GetWindowLongPtrW(windows.front(), GWL_EXSTYLE);
  SetWindowLongPtrW(windows.front(), GWL_EXSTYLE, styles & ~WS_EX_TRANSPARENT);
  Check(privacy.GetStatus().phase == "failed", "lost input transparency hidden");
  privacy.Refresh();
  Check(privacy.GetStatus().phase == "active", "cannot restore overlay contract");
  windows = Overlays();
  SetWindowDisplayAffinity(windows.front(), WDA_MONITOR);
  Check(privacy.GetStatus().phase == "failed", "MONITOR confused with exclusion");
  privacy.Deactivate();
  Check(Overlays().empty(), "failure cleanup leaked windows");
}

}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  POINT original{};
  GetCursorPos(&original);
  int result = 0;
  try {
    Run();
    std::puts("PASS: layered privacy lifecycle and cross-thread click routing");
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    result = 1;
  }
  SetCursorPos(original.x, original.y);
  return result;
}
