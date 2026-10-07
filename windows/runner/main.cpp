#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <appmodel.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Flutter's packaged native-assets manifest currently leaves sqlite3.dll
// addressable by a package-relative name, while sqlite3's FFI resolver falls
// back to process symbols. Keep the package-local module loaded for the
// process lifetime so sqlite3_initialize is discoverable without accepting an
// absolute build-machine path. Unpackaged development continues through the
// normal Flutter loader path.
void PreloadPackagedSqlite() {
  UINT32 package_path_length = 0;
  const auto package_result = GetCurrentPackagePath(&package_path_length, nullptr);
  if (package_result != ERROR_INSUFFICIENT_BUFFER &&
      package_result != ERROR_SUCCESS) {
    return;
  }
  const auto module = LoadPackagedLibrary(L"sqlite3.dll", 0);
  if (module == nullptr ||
      GetProcAddress(module, "sqlite3_initialize") == nullptr) {
    return;
  }
  // Deliberately do not call FreeLibrary: the FFI resolver may use this module
  // after startup, and the process owns the module for its full lifetime.
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  PreloadPackagedSqlite();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"synctune", origin, size)) {
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
