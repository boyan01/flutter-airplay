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
# Shared plist configuration is used by both the product and control-only tests.
function(airplay_configure_windows_plist)
  target_include_directories(plist PRIVATE "${windows_host}/compat")
  target_compile_definitions(plist PUBLIC LIBPLIST_STATIC)
  target_compile_definitions(plist PRIVATE WIN32 NOMINMAX WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000 _CRT_SECURE_NO_WARNINGS)
  # libplist calls strndup and airplay_fopen, including when its consumer does
  # not link receiver_core. Keep their implementation with the dependency.
  target_sources(plist PRIVATE "${windows_host}/compat/posix.c")
  set_source_files_properties("${windows_host}/compat/posix.c" PROPERTIES COMPILE_DEFINITIONS AIRPLAY_POSIX_IMPLEMENTATION=1)
  target_link_libraries(plist PRIVATE ws2_32)
  get_target_property(plist_sources plist SOURCES)
  set_property(SOURCE ${plist_sources} APPEND PROPERTY COMPILE_OPTIONS
    "/FI${windows_host}/compat/posix.h" "/clang:-std=gnu11")
endfunction()
if(AIRPLAY_CONTROL_ONLY)
  airplay_configure_windows_plist()
  target_compile_definitions(airplay_receiver_control PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000 _CRT_SECURE_NO_WARNINGS)
  return()
endif()
airplay_configure_windows_plist()
get_target_property(receive_sources receiver_core SOURCES)
list(FILTER receive_sources EXCLUDE REGEX "[/\\]dnssd\\.c$")
set_property(TARGET receiver_core PROPERTY SOURCES "${receive_sources}")
target_sources(receiver_core PRIVATE
  "${project_root}/native/backends/windows/windows_dnssd.cpp")
target_include_directories(receiver_core PRIVATE "${windows_host}/compat")
# Visual Studio evaluates target language options as C++ for mixed targets.
# Apply the POSIX adapter to C files without changing the DNS-SD C++ source.
set_property(SOURCE ${receive_sources}
  APPEND PROPERTY COMPILE_OPTIONS
    "/FI${windows_host}/compat/posix.h" "/clang:-std=gnu11")
set(airplay_windows_targets receiver_core plist llhttp playfair airplay_player airplay_receiver_control airplay_protocol)
if(TARGET airplay_ffi)
  list(APPEND airplay_windows_targets airplay_ffi)
endif()
foreach(target IN LISTS airplay_windows_targets)
  target_compile_definitions(${target} PRIVATE WIN32 NOMINMAX WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000 _CRT_SECURE_NO_WARNINGS)
endforeach()
if(NOT TARGET alac_decoder)
  add_subdirectory("${project_root}/vendor/alac" "${CMAKE_BINARY_DIR}/alac")
endif()
# clang-cl uses MSVC option syntax even though these codec options are LLVM's.
set_property(TARGET alac_decoder PROPERTY COMPILE_OPTIONS /clang:-fwrapv /clang:-fno-strict-aliasing)
target_sources(airplay_player PRIVATE
  "${project_root}/native/backends/windows/windows_video.cpp"
  "${project_root}/native/backends/windows/windows_audio.cpp"
  "${project_root}/native/backends/ffmpeg/ffmpeg_video.cpp"
  "${project_root}/native/backends/ffmpeg/ffmpeg_audio_decoder.cpp")
set(FFMPEG_PREFIX "${project_root}/build/windows-deps/ffmpeg-aac" CACHE PATH "Pinned MSVC FFmpeg media libraries")
target_include_directories(airplay_player SYSTEM PRIVATE "${FFMPEG_PREFIX}/include")
foreach(component avcodec avutil swresample swscale)
  find_library(FFMPEG_${component}_LIBRARY NAMES ${component}
    PATHS "${FFMPEG_PREFIX}/lib" "${FFMPEG_PREFIX}/bin" NO_DEFAULT_PATH REQUIRED)
  file(GLOB component_dll "${FFMPEG_PREFIX}/bin/${component}-*.dll")
  list(LENGTH component_dll dll_count)
  if(NOT dll_count EQUAL 1)
    message(FATAL_ERROR "Expected one ${component} DLL under ${FFMPEG_PREFIX}/bin. Rebuild the pinned Windows dependencies.")
  endif()
  target_link_libraries(airplay_player PRIVATE "${FFMPEG_${component}_LIBRARY}")
  add_custom_command(TARGET airplay_player POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${component_dll}" "$<TARGET_FILE_DIR:airplay_player>")
endforeach()
add_custom_command(TARGET airplay_player POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${FFMPEG_PREFIX}/licenses"
    "$<TARGET_FILE_DIR:airplay_player>/ffmpeg-licenses")
target_link_libraries(receiver_core PUBLIC ws2_32 dnsapi advapi32 crypt32)
target_link_libraries(airplay_player PRIVATE alac_decoder mfplat mf mfuuid wmcodecdspuuid ole32 avrt d3d11 dxgi)
set_target_properties(airplay_player PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
option(AIRPLAY_WINDOWS_BUILD_TESTS "Build Windows media / compatibility fixtures" OFF)
if(AIRPLAY_WINDOWS_BUILD_TESTS)
  enable_testing()
  add_executable(windows_pixels_test "${windows_host}/tests/pixels_test.cpp")
  target_include_directories(windows_pixels_test PRIVATE "${project_root}/native/playback")
  add_test(NAME windows_pixels COMMAND windows_pixels_test)
  add_executable(windows_video_test "${windows_host}/tests/video_test.cpp")
  target_include_directories(windows_video_test PRIVATE "${project_root}/native/playback" "${project_root}/native/tests/playback")
  target_link_libraries(windows_video_test PRIVATE airplay_player d3d11 dxgi dxguid mfplat mfuuid ole32)
  target_include_directories(windows_video_test SYSTEM PRIVATE "${FFMPEG_PREFIX}/include")
  target_link_libraries(windows_video_test PRIVATE "${FFMPEG_avutil_LIBRARY}" "${FFMPEG_swscale_LIBRARY}")
  add_test(NAME windows_video COMMAND windows_video_test)
  add_test(NAME windows_video_gpu COMMAND windows_video_test --gpu)
  add_test(NAME windows_hevc_software COMMAND windows_video_test --software)
  set_tests_properties(windows_video windows_video_gpu windows_hevc_software PROPERTIES TIMEOUT 30)
  add_executable(windows_compat_test "${windows_host}/tests/compat_test.c" "${windows_host}/compat/posix.c")
  target_include_directories(windows_compat_test PRIVATE "${windows_host}/compat")
  target_compile_definitions(windows_compat_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
  target_link_libraries(windows_compat_test PRIVATE ws2_32)
  add_test(NAME windows_compat COMMAND windows_compat_test)
  add_executable(windows_httpd_test "${windows_host}/tests/httpd_test.c")
  target_include_directories(windows_httpd_test PRIVATE "${windows_host}/compat")
  target_link_libraries(windows_httpd_test PRIVATE receiver_core)
  add_test(NAME windows_httpd COMMAND windows_httpd_test)
  set_tests_properties(windows_httpd PROPERTIES TIMEOUT 15)
  add_executable(windows_startup_test "${windows_host}/tests/startup_test.cpp")
  add_test(NAME windows_startup COMMAND windows_startup_test)
  set_tests_properties(windows_startup PROPERTIES LABELS "host" TIMEOUT 15)
  add_executable(windows_audio_clock_test "${windows_host}/tests/audio_clock_test.cpp")
  target_include_directories(windows_audio_clock_test PRIVATE "${project_root}/native/playback" "${project_root}/native/tests/playback")
  add_test(NAME windows_audio_clock COMMAND windows_audio_clock_test)
  add_executable(windows_audio_decoder_test "${project_root}/native/tests/playback/ffmpeg_audio_decoder_test.cpp")
  target_include_directories(windows_audio_decoder_test PRIVATE "${project_root}/native/playback" "${project_root}/native/tests/playback")
  target_link_libraries(windows_audio_decoder_test PRIVATE airplay_player)
  add_test(NAME windows_audio_decode_recovery COMMAND windows_audio_decoder_test)
  set_tests_properties(windows_audio_decode_recovery PROPERTIES TIMEOUT 15)
endif()

if(AIRPLAY_WINDOWS_BUILD_TESTS)
  set_tests_properties(windows_pixels windows_audio_clock PROPERTIES LABELS "playback")
  set_tests_properties(windows_video windows_video_gpu windows_hevc_software windows_audio_decode_recovery PROPERTIES LABELS "backend")
  set_tests_properties(windows_compat windows_httpd PROPERTIES LABELS "protocol")
endif()
