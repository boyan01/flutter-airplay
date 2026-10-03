# SPDX-License-Identifier: GPL-3.0-only
# Derived from jqssun/android-airplay-server; see android/NOTICE.
include(ExternalProject)
include(ProcessorCount)
if(ANDROID)
    if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
        message(FATAL_ERROR "Only arm64-v8a is packaged")
    endif()
    get_filename_component(ffmpeg_toolchain "${CMAKE_C_COMPILER}" DIRECTORY)
    set(ffmpeg_platform --target-os=android --arch=aarch64 --enable-cross-compile
        --cc=${ffmpeg_toolchain}/aarch64-linux-android26-clang
        --cxx=${ffmpeg_toolchain}/aarch64-linux-android26-clang++
        --ar=${ffmpeg_toolchain}/llvm-ar --nm=${ffmpeg_toolchain}/llvm-nm
        --ranlib=${ffmpeg_toolchain}/llvm-ranlib --strip=${ffmpeg_toolchain}/llvm-strip
        --sysroot=${CMAKE_SYSROOT})
elseif(APPLE)
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE ffmpeg_sdk OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(ffmpeg_platform --target-os=darwin --arch=aarch64 --cc=clang --cxx=clang++
        --extra-cflags=-mmacosx-version-min=12.0 --extra-ldflags=-mmacosx-version-min=12.0
        --sysroot=${ffmpeg_sdk})
else()
    message(FATAL_ERROR "Unsupported playback platform")
endif()
ProcessorCount(ffmpeg_jobs)
if(NOT ffmpeg_jobs)
    set(ffmpeg_jobs 4)
endif()
set(FFMPEG_INSTALL ${CMAKE_BINARY_DIR}/ffmpeg-shared-player)
ExternalProject_Add(ffmpeg_ep
    SOURCE_DIR ${DEPS_SOURCE}/ffmpeg
    DOWNLOAD_COMMAND ""
    PREFIX ${CMAKE_BINARY_DIR}/ffmpeg-player-ep
    INSTALL_DIR ${FFMPEG_INSTALL}
    CONFIGURE_COMMAND <SOURCE_DIR>/configure --prefix=<INSTALL_DIR> ${ffmpeg_platform}
        --enable-pic --disable-asm --disable-x86asm --disable-all --disable-debug
        --disable-network --disable-autodetect --enable-avcodec --enable-decoder=aac,alac
        --enable-static --disable-shared
    BUILD_COMMAND make -j${ffmpeg_jobs}
    INSTALL_COMMAND make install
    BUILD_BYPRODUCTS ${FFMPEG_INSTALL}/lib/libavcodec.a ${FFMPEG_INSTALL}/lib/libavutil.a
    LOG_CONFIGURE TRUE LOG_BUILD TRUE LOG_INSTALL TRUE)
file(MAKE_DIRECTORY ${FFMPEG_INSTALL}/include)
add_library(ffmpeg::avutil STATIC IMPORTED)
set_target_properties(ffmpeg::avutil PROPERTIES IMPORTED_LOCATION ${FFMPEG_INSTALL}/lib/libavutil.a
    INTERFACE_INCLUDE_DIRECTORIES ${FFMPEG_INSTALL}/include)
add_library(ffmpeg::avcodec STATIC IMPORTED)
set_target_properties(ffmpeg::avcodec PROPERTIES IMPORTED_LOCATION ${FFMPEG_INSTALL}/lib/libavcodec.a
    INTERFACE_INCLUDE_DIRECTORIES ${FFMPEG_INSTALL}/include INTERFACE_LINK_LIBRARIES ffmpeg::avutil)
