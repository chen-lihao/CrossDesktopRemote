cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_clipboard_bridge.cpp"
  "windows_device_identity_bridge.cpp"
  "windows_file_paste_target_bridge.cpp"
  "windows_host_bridge.cpp"
  "windows_lan_discovery_bridge.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX" "WIN32_LEAN_AND_MEAN")
# Native channel messages contain Chinese user-facing diagnostics and must be
# encoded as UTF-8 independently of the developer machine's active code page.
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dnsapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ws2_32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shcore.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "oleaut32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "crypt32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ncrypt.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Build and bundle the authoritative Rust security/transfer core. Flutter loads
# this DLL through Dart FFI; keeping it next to the runner also makes the same
# artifact available to Debug, Profile, and Release installations.
find_program(CROSSDESKTOP_CARGO_EXECUTABLE
  NAMES cargo cargo.exe
  HINTS "$ENV{USERPROFILE}/.cargo/bin")
if(NOT CROSSDESKTOP_CARGO_EXECUTABLE)
  message(FATAL_ERROR
    "cargo is required to build the CrossDesktopRemote Rust core")
endif()
set(CROSSDESKTOP_REPO_ROOT "${CMAKE_SOURCE_DIR}/../../..")
set(CROSSDESKTOP_RUST_RELEASE_ARG
  "$<$<NOT:$<CONFIG:Debug>>:--release>")
set(CROSSDESKTOP_RUST_PROFILE_DIR
  "$<IF:$<CONFIG:Debug>,debug,release>")
add_custom_target(crossdesktop_rust_core ALL
  COMMAND "${CROSSDESKTOP_CARGO_EXECUTABLE}" build
    --manifest-path "${CROSSDESKTOP_REPO_ROOT}/Cargo.toml"
    -p client-ffi
    ${CROSSDESKTOP_RUST_RELEASE_ARG}
  WORKING_DIRECTORY "${CROSSDESKTOP_REPO_ROOT}"
  COMMENT "Building CrossDesktopRemote Rust core"
  COMMAND_EXPAND_LISTS
  VERBATIM)
add_dependencies(${BINARY_NAME} crossdesktop_rust_core)
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CROSSDESKTOP_REPO_ROOT}/target/${CROSSDESKTOP_RUST_PROFILE_DIR}/crossdesktop_core.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/crossdesktop_core.dll"
  COMMENT "Bundling CrossDesktopRemote Rust core"
  VERBATIM)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
