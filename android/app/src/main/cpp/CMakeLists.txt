# SPDX-License-Identifier: GPL-3.0-only
# Built by Gradle (app/build.gradle.kts); native/ fetches its pinned dependencies.
cmake_minimum_required(VERSION 3.22.1)
project(flutter_airplay_android_player C CXX)
add_compile_options("-ffile-prefix-map=${CMAKE_SOURCE_DIR}=." "-ffile-prefix-map=${CMAKE_BINARY_DIR}=.")
# The lychee_player plugin's AAR publishes the core as a prefab module.
find_package(lychee REQUIRED CONFIG)
add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../../../../native ${CMAKE_BINARY_DIR}/shared)
target_sources(airplay_player PRIVATE ${CMAKE_CURRENT_LIST_DIR}/player.cpp)
