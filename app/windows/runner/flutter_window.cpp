#include "flutter_window.h"

#include <optional>
#include <string>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// "Start with Windows" registry plumbing (HKCU so the app itself can toggle it
// without elevation). The Run value matches what the NSIS installer writes:
// "\"<exe>\" --background" (launch hidden in the system tray).
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Commsuite";

std::wstring RunCommand() {
  wchar_t path[MAX_PATH];
  const DWORD len = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return L"";
  }
  return std::wstring(L"\"") + path + L"\" --background";
}

bool IsAutoStartEnabled() {
  wchar_t value[512]{};
  DWORD size = sizeof(value);
  return ::RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                        nullptr, value, &size) == ERROR_SUCCESS;
}

void SetAutoStartEnabled(bool enabled) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE,
                      &key) != ERROR_SUCCESS) {
    if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                          KEY_SET_VALUE, nullptr, &key,
                          nullptr) != ERROR_SUCCESS) {
      return;
    }
  }
  if (enabled) {
    const std::wstring cmd = RunCommand();
    ::RegSetValueExW(key, kRunValue, 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(cmd.c_str()),
                     static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
  } else {
    ::RegDeleteValueW(key, kRunValue);
  }
  ::RegCloseKey(key);
}

// Microsoft Edge WebView2 Runtime is what flutter_inappwebview uses to render
// pages on Windows. Its Evergreen version is published in the EdgeUpdate
// client registry key below (both HKLM/HKCU and 32/64-bit views). Empty means
// the runtime is missing, in which case the built-in browser cannot start at
// all ("Cannot create the InAppWebView instance!").
constexpr wchar_t kWebView2ClientKey[] =
    L"SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

std::wstring WebView2RuntimeVersion() {
  const DWORD views[] = {0, RRF_SUBKEY_WOW6432KEY};
  const HKEY roots[] = {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
  for (const HKEY root : roots) {
    for (const DWORD view : views) {
      wchar_t value[128]{};
      DWORD size = sizeof(value);
      if (::RegGetValueW(root, kWebView2ClientKey, L"pv",
                         RRF_RT_REG_SZ | view, nullptr, value, &size) ==
              ERROR_SUCCESS &&
          value[0] != L'\0') {
        return value;
      }
    }
  }
  return L"";
}

std::string ToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return "";
  }
  const int length = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  std::string utf8(length, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                        static_cast<int>(wide.size()), &utf8[0], length,
                        nullptr, nullptr);
  return utf8;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Dart <-> native bridge for the "Start with Windows" settings toggle.
  static auto autostart_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "commsuite/autostart",
          &flutter::StandardMethodCodec::GetInstance());
  autostart_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "isEnabled") {
          result->Success(flutter::EncodableValue(IsAutoStartEnabled()));
        } else if (method == "setEnabled") {
          bool enabled = false;
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            const auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end()) {
              enabled = std::get<bool>(it->second);
            }
          }
          SetAutoStartEnabled(enabled);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Dart <-> native bridge for the Microsoft Edge WebView2 Runtime probe.
  // The Browser tab uses it to offer a system-browser fallback instead of
  // throwing "Cannot create the InAppWebView instance!" when WebView2 is
  // not installed.
  static auto webview2_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "commsuite/webview2",
          &flutter::StandardMethodCodec::GetInstance());
  webview2_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "runtimeVersion") {
          result->Success(
              flutter::EncodableValue(ToUtf8(WebView2RuntimeVersion())));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
