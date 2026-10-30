# SPDX-License-Identifier: GPL-3.0-only
# The Windows native player, built with ClangCL by windows/cmake/NativePlayer.cmake
# (the receive core needs it). It links lychee_player.dll, which the lychee_player
# plugin builds in the Flutter project, through that build's import library.
cmake_minimum_required(VERSION 3.22.1)
project(airplay_windows C CXX)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(AIRPLAY_LYCHEE_INCLUDE "" CACHE PATH "lychee_player's core/include")
set(AIRPLAY_LYCHEE_IMPLIB "" CACHE FILEPATH "lychee_player.lib from the Flutter build")
if(NOT EXISTS "${AIRPLAY_LYCHEE_INCLUDE}/lychee/lychee.h" OR NOT AIRPLAY_LYCHEE_IMPLIB)
  message(FATAL_ERROR "Build through flutter build windows, which builds lychee_player")
endif()
add_library(lychee::lychee SHARED IMPORTED)
set_target_properties(lychee::lychee PROPERTIES IMPORTED_IMPLIB "${AIRPLAY_LYCHEE_IMPLIB}"
  INTERFACE_INCLUDE_DIRECTORIES "${AIRPLAY_LYCHEE_INCLUDE}")
# Native tests register in the subdirectory.
enable_testing()
add_subdirectory(../../native native)
