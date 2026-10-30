# SPDX-License-Identifier: GPL-3.0-only
# libplist from its pinned release source, on every platform.
include(${CMAKE_CURRENT_LIST_DIR}/Dependencies.cmake)
airplay_dependency(libplist plist_source)
string(JSON plist_version GET "${airplay_lock}" libplist version)
set(plist "${plist_source}/src")
set(cnary "${plist_source}/libcnary")
add_library(plist STATIC
    ${plist}/base64.c ${plist}/bplist.c ${plist}/bytearray.c ${plist}/hashtable.c
    ${plist}/jplist.c ${plist}/jsmn.c ${plist}/oplist.c ${plist}/out-default.c
    ${plist}/out-limd.c ${plist}/out-plutil.c ${plist}/plist.c ${plist}/ptrarray.c
    ${plist}/time64.c ${plist}/xplist.c
    ${cnary}/node.c ${cnary}/node_list.c)
target_include_directories(plist PUBLIC ${plist_source}/include PRIVATE ${plist} ${cnary}/include)
target_compile_definitions(plist PRIVATE _GNU_SOURCE HAVE_STRNDUP PACKAGE_VERSION="${plist_version}")
if(UNIX AND NOT APPLE)
    target_link_libraries(plist PRIVATE m)
endif()
