# SPDX-License-Identifier: GPL-3.0-only
get_filename_component(AIRPLAY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(AIRPLAY_WINDOWS_PLAYER_DIR "${AIRPLAY_ROOT}/build/windows-native" CACHE PATH "Prebuilt ClangCL player directory")
find_package(Python3 COMPONENTS Interpreter REQUIRED)
if(AIRPLAY_WINDOWS_PLAYER_DIR STREQUAL "${AIRPLAY_ROOT}/build/windows-native")
  # Runtime DLL names must be available while configuring installation rules.
  execute_process(COMMAND "${Python3_EXECUTABLE}" "${AIRPLAY_ROOT}/scripts/ensure_native.py" windows
    RESULT_VARIABLE native_result)
  if(NOT native_result EQUAL 0)
    message(FATAL_ERROR "Windows native preparation failed; see the build output and DEVELOPMENT.md for toolchain requirements.")
  endif()
  # Check again on ordinary builds, when CMake configuration is already current.
  add_custom_target(prepare_native_player
    COMMAND "${Python3_EXECUTABLE}" "${AIRPLAY_ROOT}/scripts/ensure_native.py" windows
    VERBATIM)
  add_dependencies(${BINARY_NAME} prepare_native_player)
endif()
if(NOT EXISTS "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.dll" OR
   NOT EXISTS "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.lib")
  message(FATAL_ERROR "Windows native player is missing. Run powershell -File windows/scripts/build_native.ps1 from the repository root first.")
endif()
add_library(airplay_player_import SHARED IMPORTED)
set_target_properties(airplay_player_import PROPERTIES
  IMPORTED_LOCATION "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.dll"
  IMPORTED_IMPLIB "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.lib"
  INTERFACE_INCLUDE_DIRECTORIES "${AIRPLAY_ROOT}/native/player")
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.dll" "$<TARGET_FILE_DIR:${BINARY_NAME}>")
install(FILES "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/airplay_player.dll" DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
foreach(component avcodec avutil swresample swscale)
  file(GLOB component_dll "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/${component}-*.dll")
  list(LENGTH component_dll dll_count)
  if(NOT dll_count EQUAL 1)
    message(FATAL_ERROR "Missing or ambiguous FFmpeg ${component} runtime. Rebuild the Windows native player first.")
  endif()
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${component_dll}" "$<TARGET_FILE_DIR:${BINARY_NAME}>")
  install(FILES "${component_dll}" DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
endforeach()
install(DIRECTORY "${AIRPLAY_WINDOWS_PLAYER_DIR}/Release/ffmpeg-licenses/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses/FFmpeg" COMPONENT Runtime)
install(FILES "${AIRPLAY_ROOT}/LICENSE" "${AIRPLAY_ROOT}/THIRD_PARTY_NOTICES.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses" COMPONENT Runtime)
install(DIRECTORY "${AIRPLAY_ROOT}/android/app/src/main/assets/licenses/" DESTINATION "${CMAKE_INSTALL_PREFIX}/data/licenses" COMPONENT Runtime)
