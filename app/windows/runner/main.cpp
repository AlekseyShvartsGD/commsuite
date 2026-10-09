#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A second commsuite.exe must not run: two processes would fight over the
  // shared WebView2 user-data folder (<exe>.WebView2), which makes the second
  // one fail with "Cannot create the InAppWebView instance!". Enforce a
  // session-local single instance and surface the existing window instead.
  // Local\ is session-scoped and shared across integrity levels, so it works
  // whether the running copy is elevated or not.
  const wchar_t kMutexName[] = L"Local\\Commsuite.SingleInstance";
  HANDLE mutex =
      ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Leave a trace for diagnosing why an instance exited at startup.
    wchar_t path[MAX_PATH];
    if (::ExpandEnvironmentStringsW(
            L"%LOCALAPPDATA%\\Commsuite\\second-instance.log", path,
            MAX_PATH) > 0) {
      wchar_t dir[MAX_PATH];
      if (::ExpandEnvironmentStringsW(L"%LOCALAPPDATA%\\Commsuite", dir,
                                      MAX_PATH) > 0) {
        ::CreateDirectoryW(dir, nullptr);
      }
      if (HANDLE log = ::CreateFileW(path, FILE_APPEND_DATA,
                                     FILE_SHARE_READ | FILE_SHARE_WRITE,
                                     nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                     nullptr);
          log != INVALID_HANDLE_VALUE) {
        SYSTEMTIME st;
        ::GetLocalTime(&st);
        char line[128];
        int n = wsprintfA(
            line,
            "%04u-%02u-%02u %02u:%02u:%02u second instance blocked (%lu)\r\n",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
            ::GetCurrentProcessId());
        DWORD written = 0;
        ::WriteFile(log, line, static_cast<DWORD>(n), &written, nullptr);
        ::CloseHandle(log);
      }
    }
    // Bring the existing window forward. The window class name is the stable
    // Flutter embedder class; the title may have been changed at runtime.
    HWND first = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (first && ::IsWindow(first)) {
      ::ShowWindow(first, SW_RESTORE);
      ::SetForegroundWindow(first);
    }
    return 0;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"commsuite", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
