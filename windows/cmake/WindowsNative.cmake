# SPDX-License-Identifier: GPL-3.0-only
# Included by native/CMakeLists.txt after receiver_core / airplay_player exist.
if(NOT WIN32)
  message(FATAL_ERROR "WindowsNative.cmake requires a Windows target")
endif()
if(NOT CMAKE_C_COMPILER_ID MATCHES "Clang")
  message(FATAL_ERROR "Build the Windows native player with the Visual Studio ClangCL toolset; the receive core uses C features unsupported by MSVC")
endif()
get_filename_component(windows_host "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
get_filename_component(project_root "${windows_host}/.." ABSOLUTE)
get_target_property(receive_sources receiver_core SOURCES)
list(FILTER receive_sources EXCLUDE REGEX "[/\\]dnssd\\.c$")
set_property(TARGET receiver_core PROPERTY SOURCES "${receive_sources}")
target_sources(receiver_core PRIVATE
  "${project_root}/native/player/windows_dnssd.cpp"
  "${windows_host}/compat/posix.c")
set_source_files_properties("${windows_host}/compat/posix.c" PROPERTIES COMPILE_DEFINITIONS AIRPLAY_POSIX_IMPLEMENTATION=1)
foreach(target receiver_core plist)
  target_include_directories(${target} PRIVATE "${windows_host}/compat")
  target_compile_options(${target} PRIVATE
    "$<$<COMPILE_LANGUAGE:C>:/FI${windows_host}/compat/posix.h>"
    "$<$<COMPILE_LANGUAGE:C>:/clang:-std=gnu11>")
endforeach()
foreach(target receiver_core plist llhttp playfair airplay_player)
  target_compile_definitions(${target} PRIVATE WIN32 NOMINMAX WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000 _CRT_SECURE_NO_WARNINGS)
endforeach()
if(NOT TARGET alac_decoder)
  add_subdirectory("${project_root}/vendor/alac" "${CMAKE_BINARY_DIR}/alac")
endif()
# clang-cl uses MSVC option syntax even though these codec options are LLVM's.
set_property(TARGET alac_decoder PROPERTY COMPILE_OPTIONS /clang:-fwrapv /clang:-fno-strict-aliasing)
target_sources(airplay_player PRIVATE
  "${project_root}/native/player/windows_video.cpp"
  "${project_root}/native/player/windows_audio.cpp"
  "${project_root}/native/player/windows_audio_decoder.cpp")
target_link_libraries(receiver_core PUBLIC ws2_32 dnsapi advapi32 crypt32)
target_link_libraries(airplay_player PRIVATE alac_decoder mfplat mf mfuuid wmcodecdspuuid ole32 avrt)
set_target_properties(airplay_player PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
option(AIRPLAY_WINDOWS_BUILD_TESTS "Build Windows media / compatibility fixtures" OFF)
if(AIRPLAY_WINDOWS_BUILD_TESTS)
  enable_testing()
  add_executable(windows_pixels_test "${windows_host}/tests/pixels_test.cpp")
  target_include_directories(windows_pixels_test PRIVATE "${project_root}/native/player")
  add_test(NAME windows_pixels COMMAND windows_pixels_test)
  add_executable(windows_compat_test "${windows_host}/tests/compat_test.c" "${windows_host}/compat/posix.c")
  target_include_directories(windows_compat_test PRIVATE "${windows_host}/compat")
  target_compile_definitions(windows_compat_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
  target_link_libraries(windows_compat_test PRIVATE ws2_32)
  add_test(NAME windows_compat COMMAND windows_compat_test)
endif()
