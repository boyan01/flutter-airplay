# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.22.1)
project(flutter_airplay_android_player C CXX)
add_compile_options("-ffile-prefix-map=${CMAKE_SOURCE_DIR}=." "-ffile-prefix-map=${CMAKE_BINARY_DIR}=.")
add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../../../../native ${CMAKE_BINARY_DIR}/shared)
target_sources(airplay_player PRIVATE ${CMAKE_CURRENT_LIST_DIR}/player.cpp)
