# SPDX-License-Identifier: GPL-3.0-only
function(airplay_configure_linux_player target)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LINUX_MEDIA REQUIRED IMPORTED_TARGET
    libavcodec>=60 libavutil libswscale libswresample libpulse)
  find_package(Threads REQUIRED)
  if(NOT TARGET alac_decoder)
    add_subdirectory(${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../vendor/alac
      ${CMAKE_CURRENT_BINARY_DIR}/alac)
  endif()
  target_sources(${target} PRIVATE
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/player/linux_audio.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/player/ffmpeg_audio_decoder.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/player/linux_video.cpp
    ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../native/player/ffmpeg_video.cpp)
  target_link_libraries(${target} PRIVATE PkgConfig::LINUX_MEDIA alac_decoder Threads::Threads)
endfunction()
