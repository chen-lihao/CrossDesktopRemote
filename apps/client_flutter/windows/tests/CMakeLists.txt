cmake_minimum_required(VERSION 3.14)
project(crossdesktop_windows_native_tests LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "These tests require an interactive Windows desktop")
endif()

enable_testing()
add_executable(privacy_screen_test
  privacy_screen_test.cpp
  ../runner/windows_privacy_screen.cpp
  ../runner/Runner.exe.manifest
)
target_include_directories(privacy_screen_test PRIVATE ../runner)
target_compile_features(privacy_screen_test PRIVATE cxx_std_17)
target_compile_definitions(privacy_screen_test PRIVATE
  NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
if(MSVC)
  target_compile_options(privacy_screen_test PRIVATE /W4 /WX /EHsc /utf-8)
endif()
target_link_libraries(privacy_screen_test PRIVATE user32 gdi32 dwmapi)
add_test(NAME privacy_screen_click_through COMMAND privacy_screen_test)
set_tests_properties(privacy_screen_click_through PROPERTIES TIMEOUT 60)
