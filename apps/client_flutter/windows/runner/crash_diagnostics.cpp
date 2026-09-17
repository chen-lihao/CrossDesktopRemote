#include "crash_diagnostics.h"

#include <windows.h>
#include <DbgHelp.h>
#include <ShlObj.h>

#include <atomic>
#include <cwchar>

namespace {

constexpr wchar_t kApplicationDirectory[] = L"CrossDesktopRemote";
constexpr wchar_t kCrashDirectory[] = L"Crashes";

wchar_t g_crash_directory[MAX_PATH] = {};
std::atomic_flag g_dump_in_progress = ATOMIC_FLAG_INIT;

LONG WINAPI WriteUnhandledExceptionDump(EXCEPTION_POINTERS* exception) {
  if (g_dump_in_progress.test_and_set() || g_crash_directory[0] == L'\0') {
    return EXCEPTION_EXECUTE_HANDLER;
  }

  SYSTEMTIME now{};
  GetSystemTime(&now);
  wchar_t dump_path[MAX_PATH] = {};
  const int written = swprintf_s(
      dump_path, L"%ls\\crash-%04u%02u%02u-%02u%02u%02u-%lu.dmp",
      g_crash_directory, now.wYear, now.wMonth, now.wDay, now.wHour,
      now.wMinute, now.wSecond, GetCurrentProcessId());
  if (written <= 0) {
    return EXCEPTION_EXECUTE_HANDLER;
  }

  const HANDLE file = CreateFileW(
      dump_path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return EXCEPTION_EXECUTE_HANDLER;
  }

  MINIDUMP_EXCEPTION_INFORMATION information{};
  information.ThreadId = GetCurrentThreadId();
  information.ExceptionPointers = exception;
  information.ClientPointers = FALSE;
  constexpr auto dump_type = static_cast<MINIDUMP_TYPE>(
      MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules);
  MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file,
                    dump_type, exception == nullptr ? nullptr : &information,
                    nullptr, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
  return EXCEPTION_EXECUTE_HANDLER;
}

bool CreateCrashDirectory() {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &local_app_data)) ||
      local_app_data == nullptr) {
    return false;
  }

  wchar_t application_directory[MAX_PATH] = {};
  const int application_length = swprintf_s(
      application_directory, L"%ls\\%ls", local_app_data,
      kApplicationDirectory);
  CoTaskMemFree(local_app_data);
  if (application_length <= 0 ||
      (CreateDirectoryW(application_directory, nullptr) == FALSE &&
       GetLastError() != ERROR_ALREADY_EXISTS)) {
    return false;
  }

  const int crash_length = swprintf_s(
      g_crash_directory, L"%ls\\%ls", application_directory,
      kCrashDirectory);
  return crash_length > 0 &&
         (CreateDirectoryW(g_crash_directory, nullptr) != FALSE ||
          GetLastError() == ERROR_ALREADY_EXISTS);
}

}  // namespace

void InstallCrashDiagnostics() {
  if (!CreateCrashDirectory()) {
    return;
  }
  SetUnhandledExceptionFilter(WriteUnhandledExceptionDump);
}
