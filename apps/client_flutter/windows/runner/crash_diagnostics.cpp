#include "crash_diagnostics.h"

#include <DbgHelp.h>
#include <ShlObj.h>
#include <windows.h>

#include <atomic>
#include <cwchar>

namespace {

constexpr wchar_t kApplicationDirectory[] = L"CrossDesktopRemote";
constexpr wchar_t kCrashDirectory[] = L"Crashes";

wchar_t g_crash_directory[MAX_PATH] = {};
std::atomic_flag g_dump_in_progress = ATOMIC_FLAG_INIT;
PVOID g_vectored_exception_handler = nullptr;

bool IsFatalException(const DWORD code) {
  switch (code) {
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
    case EXCEPTION_ILLEGAL_INSTRUCTION:
    case EXCEPTION_INT_DIVIDE_BY_ZERO:
    case EXCEPTION_STACK_OVERFLOW:
    case 0xC0000409:  // STATUS_STACK_BUFFER_OVERRUN / fail-fast.
    case 0xC000041D:  // STATUS_FATAL_USER_CALLBACK_EXCEPTION.
      return true;
    default:
      return false;
  }
}

bool WriteExceptionDump(EXCEPTION_POINTERS* exception) {
  if (g_dump_in_progress.test_and_set() || g_crash_directory[0] == L'\0') {
    return false;
  }

  SYSTEMTIME now{};
  GetSystemTime(&now);
  wchar_t dump_path[MAX_PATH] = {};
  const int written =
      swprintf_s(dump_path, L"%ls\\crash-%04u%02u%02u-%02u%02u%02u-%lu.dmp",
                 g_crash_directory, now.wYear, now.wMonth, now.wDay, now.wHour,
                 now.wMinute, now.wSecond, GetCurrentProcessId());
  if (written <= 0) {
    g_dump_in_progress.clear();
    return false;
  }

  const HANDLE file = CreateFileW(
      dump_path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    g_dump_in_progress.clear();
    return false;
  }

  MINIDUMP_EXCEPTION_INFORMATION information{};
  information.ThreadId = GetCurrentThreadId();
  information.ExceptionPointers = exception;
  information.ClientPointers = FALSE;
  constexpr auto dump_type = static_cast<MINIDUMP_TYPE>(
      MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules);
  const BOOL success = MiniDumpWriteDump(
      GetCurrentProcess(), GetCurrentProcessId(), file, dump_type,
      exception == nullptr ? nullptr : &information, nullptr, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
  if (!success) {
    g_dump_in_progress.clear();
  }
  return success != FALSE;
}

LONG CALLBACK WriteVectoredExceptionDump(EXCEPTION_POINTERS* exception) {
  if (exception != nullptr && exception->ExceptionRecord != nullptr &&
      IsFatalException(exception->ExceptionRecord->ExceptionCode)) {
    WriteExceptionDump(exception);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

LONG WINAPI WriteUnhandledExceptionDump(EXCEPTION_POINTERS* exception) {
  WriteExceptionDump(exception);
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
  const int application_length =
      swprintf_s(application_directory, L"%ls\\%ls", local_app_data,
                 kApplicationDirectory);
  CoTaskMemFree(local_app_data);
  if (application_length <= 0 ||
      (CreateDirectoryW(application_directory, nullptr) == FALSE &&
       GetLastError() != ERROR_ALREADY_EXISTS)) {
    return false;
  }

  const int crash_length = swprintf_s(g_crash_directory, L"%ls\\%ls",
                                      application_directory, kCrashDirectory);
  return crash_length > 0 &&
         (CreateDirectoryW(g_crash_directory, nullptr) != FALSE ||
          GetLastError() == ERROR_ALREADY_EXISTS);
}

}  // namespace

void InstallCrashDiagnostics() {
  if (!CreateCrashDirectory()) {
    return;
  }
  if (g_vectored_exception_handler == nullptr) {
    g_vectored_exception_handler =
        AddVectoredExceptionHandler(1, WriteVectoredExceptionDump);
  }
  // Flutter or a native plugin can replace the process filter during engine
  // startup, so callers intentionally reinstall this after window creation.
  SetUnhandledExceptionFilter(WriteUnhandledExceptionDump);
}
