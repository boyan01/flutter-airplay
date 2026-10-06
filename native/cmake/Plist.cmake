# SPDX-License-Identifier: GPL-3.0-only
if(PLIST_SOURCE)
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
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PLIST REQUIRED IMPORTED_TARGET libplist-2.0>=2.3)
    add_library(plist INTERFACE)
    target_link_libraries(plist INTERFACE PkgConfig::PLIST)
endif()
