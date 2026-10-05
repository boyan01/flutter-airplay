# SPDX-License-Identifier: GPL-3.0-only
# Generate at build time so incremental builds do not retain configure-time dates.
set(build_info_dir "${CMAKE_CURRENT_BINARY_DIR}/${AIRPLAY_BUILD_INFO_TARGET}-build-info")
file(MAKE_DIRECTORY "${build_info_dir}")
add_custom_target(${AIRPLAY_BUILD_INFO_TARGET}_build_info
  COMMAND "${CMAKE_COMMAND}" "-DOUTPUT=${build_info_dir}/build_info.h"
    -P "${CMAKE_CURRENT_LIST_DIR}/write_build_time.cmake"
  BYPRODUCTS "${build_info_dir}/build_info.h"
  VERBATIM
)
add_dependencies(${AIRPLAY_BUILD_INFO_TARGET} ${AIRPLAY_BUILD_INFO_TARGET}_build_info)
target_include_directories(${AIRPLAY_BUILD_INFO_TARGET} PRIVATE "${build_info_dir}")
