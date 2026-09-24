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

 private:
  bool Rebuild();

  std::vector<HWND> windows_;
  std::wstring controller_label_;
  std::string failure_reason_;
  bool capture_excluded_ = false;
  bool active_ = false;
};

#endif  // RUNNER_WINDOWS_PRIVACY_SCREEN_H_
