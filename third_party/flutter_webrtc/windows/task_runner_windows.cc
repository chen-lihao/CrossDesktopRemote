// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "task_runner_windows.h"

#include <algorithm>
#include <exception>
#include <iostream>
#include <utility>

namespace flutter_webrtc_plugin {

TaskRunnerWindows::TaskRunnerWindows() {
  WNDCLASS window_class = RegisterWindowClass();
  window_instance_ = window_class.hInstance;
  window_handle_.store(
      CreateWindowEx(0, window_class.lpszClassName, L"", 0, 0, 0, 0, 0,
                     HWND_MESSAGE, nullptr, window_class.hInstance, nullptr),
      std::memory_order_release);

  const HWND window = window_handle_.load(std::memory_order_acquire);
  if (window) {
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  } else {
    auto error = GetLastError();
    LPWSTR message = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                   reinterpret_cast<LPWSTR>(&message), 0, NULL);
    OutputDebugString(message);
    LocalFree(message);
  }
}

TaskRunnerWindows::~TaskRunnerWindows() {
  Shutdown();
}

void TaskRunnerWindows::Shutdown() {
  if (!accepting_tasks_.exchange(false, std::memory_order_acq_rel)) {
    return;
  }

  const HWND window =
      window_handle_.exchange(nullptr, std::memory_order_acq_rel);
  if (window) {
    // A posted WM_NULL must never be able to recover this object after the
    // plugin starts shutting down.
    SetWindowLongPtr(window, GWLP_USERDATA, 0);
    DestroyWindow(window);
  }

  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    std::queue<TaskClosure> empty;
    tasks_.swap(empty);
  }

  if (owns_window_class_) {
    UnregisterClass(window_class_name_.c_str(), window_instance_);
    owns_window_class_ = false;
  }
}

void TaskRunnerWindows::EnqueueTask(TaskClosure task) {
  if (!accepting_tasks_.load(std::memory_order_acquire)) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    if (!accepting_tasks_.load(std::memory_order_relaxed)) {
      return;
    }
    tasks_.push(std::move(task));
  }

  const HWND window = window_handle_.load(std::memory_order_acquire);
  if (window != nullptr && !PostMessage(window, WM_NULL, 0, 0)) {
    DWORD error_code = GetLastError();
    std::cerr << "Failed to post message to main thread; error_code: "
              << error_code << std::endl;
  }
}

void TaskRunnerWindows::ProcessTasks() {
  // Even though it would usually be sufficient to process only a single task
  // whenever we receive the message, if the message queue happens to be full,
  // we might not receive a message for each individual task.
  for (;;) {
    TaskClosure task;
    {
      std::lock_guard<std::mutex> lock(tasks_mutex_);
      if (tasks_.empty()) {
        break;
      }
      task = std::move(tasks_.front());
      tasks_.pop();
    }

    // Never hold tasks_mutex_ while running plugin code. Besides avoiding
    // re-entrant deadlocks, this keeps C++ exceptions from escaping WndProc
    // as STATUS_FATAL_USER_CALLBACK_EXCEPTION (0xC000041D).
    try {
      task();
    } catch (const std::exception& exception) {
      std::string message =
          std::string("FlutterWebRTC platform task failed: ") +
          exception.what() + "\n";
      OutputDebugStringA(message.c_str());
    } catch (...) {
      OutputDebugStringA("FlutterWebRTC platform task failed\n");
    }
  }
}

WNDCLASS TaskRunnerWindows::RegisterWindowClass() {
  window_class_name_ = L"FlutterWebRTCWindowsTaskRunnerWindow";

  WNDCLASS window_class{};
  window_class.hCursor = nullptr;
  window_class.lpszClassName = window_class_name_.c_str();
  window_class.style = 0;
  window_class.cbClsExtra = 0;
  window_class.cbWndExtra = 0;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hIcon = nullptr;
  window_class.hbrBackground = 0;
  window_class.lpszMenuName = nullptr;
  window_class.lpfnWndProc = WndProc;
  owns_window_class_ = RegisterClass(&window_class) != 0;
  return window_class;
}

LRESULT
TaskRunnerWindows::HandleMessage(UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NULL:
      if (accepting_tasks_.load(std::memory_order_acquire)) {
        ProcessTasks();
      }
      return 0;
  }
  return DefWindowProcW(window_handle_.load(std::memory_order_acquire), message,
                        wparam, lparam);
}

LRESULT TaskRunnerWindows::WndProc(HWND const window,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept {
  if (auto* that = reinterpret_cast<TaskRunnerWindows*>(
          GetWindowLongPtr(window, GWLP_USERDATA))) {
    return that->HandleMessage(message, wparam, lparam);
  } else {
    return DefWindowProc(window, message, wparam, lparam);
  }
}

}  // namespace flutter_webrtc_plugin
