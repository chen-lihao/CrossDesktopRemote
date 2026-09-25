#ifndef RUNNER_WINDOWS_PRIVACY_SCREEN_H_
#define RUNNER_WINDOWS_PRIVACY_SCREEN_H_

#include <windows.h>

#include <string>
#include <vector>

class WindowsPrivacyScreen {
 public:
  struct Status {
    std::string phase = "inactive";
    int covered_display_count = 0;
    int expected_display_count = 0;
    bool capture_excluded = false;
    bool input_transparent = false;
    std::string failure_reason;
  };

  WindowsPrivacyScreen();
  ~WindowsPrivacyScreen();

  WindowsPrivacyScreen(const WindowsPrivacyScreen&) = delete;
  WindowsPrivacyScreen& operator=(const WindowsPrivacyScreen&) = delete;

  Status Activate(const std::string& controller_label);
  void Deactivate();
  void Refresh();
  Status GetStatus() const;
  int DisplayCount() const;
  static std::string AvailabilityFailure();

  // Used only for the application's own caption-command arbitration. Actual
  // pointer input stays in SendInput; the visual overlay never forwards it.
  HWND InputTargetAtPoint(const POINT& point) const;

 private:
  bool Rebuild();

  std::vector<HWND> windows_;
  std::wstring controller_label_;
  std::string failure_reason_;
  bool active_ = false;
};

#endif  // RUNNER_WINDOWS_PRIVACY_SCREEN_H_
