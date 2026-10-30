# SPDX-License-Identifier: GPL-3.0-only
# The native player (windows/player), a nested CMake build with the Visual Studio
# ClangCL toolset that the receive core needs. It links the import library of
# lychee_player.dll, which the lychee_player plugin builds in this project.
include(ExternalProject)
get_filename_component(AIRPLAY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(AIRPLAY_NATIVE_DIR "${CMAKE_BINARY_DIR}/native")
set(airplay_player "${AIRPLAY_NATIVE_DIR}/Release/airplay_player")
get_target_property(airplay_lychee_include lychee INTERFACE_INCLUDE_DIRECTORIES)
ExternalProject_Add(airplay_native
  SOURCE_DIR "${AIRPLAY_ROOT}/windows/player"
  BINARY_DIR "${AIRPLAY_NATIVE_DIR}"
  CMAKE_GENERATOR "${CMAKE_GENERATOR}"
  CMAKE_GENERATOR_PLATFORM x64
  CMAKE_GENERATOR_TOOLSET ClangCL
  CMAKE_ARGS
    "-DAIRPLAY_LYCHEE_INCLUDE=${airplay_lychee_include}"
    "-DAIRPLAY_LYCHEE_IMPLIB=$<TARGET_LINKER_FILE:lychee>"
    "-DFLUTTER_ROOT=${FLUTTER_ROOT}"
  # The player always builds optimized; the nested build is incremental.
  BUILD_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --config Release --target airplay_player
  BUILD_ALWAYS ON
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${airplay_player}.dll" "${airplay_player}.lib"
  DEPENDS lychee)
add_library(airplay_player_import SHARED IMPORTED GLOBAL)
set_target_properties(airplay_player_import PROPERTIES
  IMPORTED_LOCATION "${airplay_player}.dll"
  IMPORTED_IMPLIB "${airplay_player}.lib"
  INTERFACE_INCLUDE_DIRECTORIES "${AIRPLAY_ROOT}/native/include/airplay")
add_dependencies(${BINARY_NAME} airplay_native)
# Installed into the bundle beside the plugins' DLLs.
install(FILES "${airplay_player}.dll" DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${AIRPLAY_ROOT}/LICENSE" "${AIRPLAY_ROOT}/THIRD_PARTY_NOTICES.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses" COMPONENT Runtime)
install(DIRECTORY "${AIRPLAY_ROOT}/assets/licenses/" DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses" COMPONENT Runtime)
