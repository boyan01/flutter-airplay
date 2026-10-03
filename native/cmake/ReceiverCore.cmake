# SPDX-License-Identifier: GPL-3.0-only
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
add_library(receiver_core STATIC ${core_sources})
if(ANDROID OR AIRPLAY_DNS_STUB)
    target_sources(receiver_core PRIVATE ${CMAKE_CURRENT_LIST_DIR}/../../android/app/src/main/cpp/dns_sd.c)
    target_include_directories(receiver_core PRIVATE ${CMAKE_CURRENT_LIST_DIR}/../../android/app/src/main/cpp)
endif()
target_include_directories(receiver_core PUBLIC ${core}
    PRIVATE ${CRYPTO_PREFIX}/include)
target_compile_definitions(receiver_core PRIVATE PLIST_210 PLIST_230 OPENSSL_API_COMPAT=0x10101000L)
find_library(crypto_library crypto PATHS ${CRYPTO_PREFIX}/lib ${CRYPTO_PREFIX}/lib64 NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)
target_link_libraries(receiver_core PUBLIC plist llhttp playfair ${crypto_library})
