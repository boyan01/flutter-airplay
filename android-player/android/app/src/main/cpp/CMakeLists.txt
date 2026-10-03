# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.22.1)
project(flutter_airplay_android_player C CXX)
option(HOST_SANITIZE "Enable address and undefined behavior checks for host tests" OFF)
if(HOST_SANITIZE AND NOT ANDROID)
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
add_compile_options("-ffile-prefix-map=${CMAKE_SOURCE_DIR}=." "-ffile-prefix-map=${CMAKE_BINARY_DIR}=.")
if(NOT UXPLAY_SOURCE OR NOT PLIST_SOURCE OR NOT CRYPTO_PREFIX)
    message(FATAL_ERROR "UXPLAY_SOURCE, PLIST_SOURCE and CRYPTO_PREFIX are required")
endif()
set(core "${UXPLAY_SOURCE}/lib")
set(plist "${PLIST_SOURCE}/src")
set(cnary "${PLIST_SOURCE}/libcnary")
add_library(plist STATIC
    ${plist}/base64.c ${plist}/bplist.c ${plist}/bytearray.c ${plist}/hashtable.c
    ${plist}/jplist.c ${plist}/jsmn.c ${plist}/oplist.c ${plist}/out-default.c
    ${plist}/out-limd.c ${plist}/out-plutil.c ${plist}/plist.c ${plist}/ptrarray.c
    ${plist}/time64.c ${plist}/xplist.c
    ${cnary}/cnary.c ${cnary}/node.c ${cnary}/node_list.c)
target_include_directories(plist PUBLIC ${PLIST_SOURCE}/include PRIVATE ${plist} ${cnary}/include)
target_compile_definitions(plist PRIVATE _GNU_SOURCE HAVE_STRNDUP PACKAGE_VERSION="2.6.0")
add_library(llhttp STATIC ${core}/llhttp/api.c ${core}/llhttp/http.c ${core}/llhttp/llhttp.c)
target_include_directories(llhttp PUBLIC ${core}/llhttp)
add_library(playfair STATIC ${core}/playfair/hand_garble.c ${core}/playfair/modified_md5.c
    ${core}/playfair/omg_hax.c ${core}/playfair/playfair.c ${core}/playfair/sap_hash.c)
target_include_directories(playfair PUBLIC ${core}/playfair)
file(GLOB core_sources CONFIGURE_DEPENDS "${core}/*.c")
add_library(receiver_core STATIC ${core_sources} ${FOUNDATION_SOURCE}/dns_sd.c)
target_include_directories(receiver_core PUBLIC ${core} ${FOUNDATION_SOURCE}
    PRIVATE ${CRYPTO_PREFIX}/include)
target_compile_definitions(receiver_core PRIVATE PLIST_210 PLIST_230 OPENSSL_API_COMPAT=0x10101000L)
find_library(crypto_library crypto PATHS ${CRYPTO_PREFIX}/lib ${CRYPTO_PREFIX}/lib64 NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)
target_link_libraries(receiver_core PUBLIC plist llhttp playfair ${crypto_library})

set(AIRPLAY_ANDROID_API 26)
include(BuildFFmpeg.cmake)
set(OBOE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(OBOE_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(${DEPS_SOURCE}/oboe ${CMAKE_BINARY_DIR}/oboe)
add_library(airplay_player SHARED player.cpp audio_engine.cpp)
add_dependencies(airplay_player ffmpeg_ep)
target_link_libraries(airplay_player PRIVATE receiver_core ffmpeg::avcodec oboe mediandk android log m)
target_compile_definitions(receiver_core PRIVATE TARGET_RT_LITTLE_ENDIAN=1)
target_link_options(airplay_player PRIVATE "-Wl,-z,max-page-size=16384")
