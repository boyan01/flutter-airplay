# SPDX-License-Identifier: GPL-3.0-only
# The macOS and iOS native player. Xcode runs this after the lychee_player
# plugin's Swift package has put lychee.framework in BUILT_PRODUCTS_DIR,
# passed as AIRPLAY_LYCHEE_FRAMEWORK; the player links it.
cmake_minimum_required(VERSION 3.22.1)
project(airplay_apple C CXX)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(AIRPLAY_LYCHEE_FRAMEWORK "" CACHE PATH "The lychee_player plugin's lychee.framework")
if(NOT EXISTS "${AIRPLAY_LYCHEE_FRAMEWORK}/Headers/lychee.h")
    message(FATAL_ERROR "Build through Xcode or flutter build: the player links the plugin's lychee.framework")
endif()
get_filename_component(lychee_framework_dir "${AIRPLAY_LYCHEE_FRAMEWORK}" DIRECTORY)
add_library(lychee::lychee UNKNOWN IMPORTED)
set_target_properties(lychee::lychee PROPERTIES IMPORTED_LOCATION "${AIRPLAY_LYCHEE_FRAMEWORK}/lychee"
    INTERFACE_COMPILE_OPTIONS "-F${lychee_framework_dir}")
# Native tests register in the subdirectory.
enable_testing()
add_subdirectory(.. native)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # One archive for the app: the static player and every library it links.
    set(archives airplay_player receiver_core plist llhttp playfair crypto ssl decrepit)
    set(archive_files)
    foreach(archive IN LISTS archives)
        list(APPEND archive_files "$<TARGET_FILE:${archive}>")
    endforeach()
    add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/libAirplayPlayer.a"
        COMMAND libtool -static -o "${CMAKE_BINARY_DIR}/libAirplayPlayer.a" ${archive_files}
        DEPENDS ${archives} VERBATIM)
    add_custom_target(airplay_player_archive DEPENDS "${CMAKE_BINARY_DIR}/libAirplayPlayer.a")
endif()
