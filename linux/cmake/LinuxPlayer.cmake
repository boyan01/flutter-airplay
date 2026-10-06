# SPDX-License-Identifier: GPL-3.0-only
function(airplay_configure_linux_player target)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LINUX_MEDIA REQUIRED IMPORTED_TARGET
    libavcodec>=60 libavutil libswscale libswresample libpulse)
  find_package(Threads REQUIRED)
  pkg_check_modules(LINUX_GL REQUIRED IMPORTED_TARGET epoxy)
  find_path(AIRPLAY_FFNV_INCLUDE ffnvcodec/dynlink_cuda.h)
  if(AIRPLAY_FFNV_INCLUDE)
    target_include_directories(${target} PRIVATE "${AIRPLAY_FFNV_INCLUDE}")
    target_compile_definitions(${target} PRIVATE AIRPLAY_CUDA_INTEROP=1)
  else()
    message(STATUS "CUDA/OpenGL interop unavailable: install nv-codec-headers; hardware download fallback remains enabled")
  endif()
  if(NOT TARGET alac_decoder)
    add_subdirectory(${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../vendor/alac
      ${CMAKE_CURRENT_BINARY_DIR}/alac)
  endif()
  target_sources(${target} PRIVATE
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/backends/linux/linux_audio.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/backends/ffmpeg/ffmpeg_audio_decoder.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/backends/linux/linux_gpu.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/backends/linux/linux_video.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/backends/ffmpeg/ffmpeg_video.cpp)
  target_link_libraries(${target} PRIVATE PkgConfig::LINUX_MEDIA PkgConfig::LINUX_GL ${CMAKE_DL_LIBS} alac_decoder Threads::Threads)
endfunction()
