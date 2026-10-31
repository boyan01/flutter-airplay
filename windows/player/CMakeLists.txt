# SPDX-License-Identifier: GPL-3.0-only
# The Windows native player, built with ClangCL by windows/cmake/NativePlayer.cmake
# (the receive core needs it). It links lychee_player.dll, which the lychee_player
# plugin builds in the Flutter project and exports as the lychee CMake package.
cmake_minimum_required(VERSION 3.22.1)
project(airplay_windows C CXX)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
find_package(lychee CONFIG REQUIRED)
# Native tests register in the subdirectory.
enable_testing()
add_subdirectory(../../native native)
