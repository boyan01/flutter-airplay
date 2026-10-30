# SPDX-License-Identifier: GPL-3.0-only
# The receive core's libcrypto: the distribution's OpenSSL 3 on Linux, and the
# pinned BoringSSL, built from source, everywhere else. Both are Apache-2.0.
include_guard(GLOBAL)
add_library(airplay_crypto INTERFACE)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(OpenSSL 3 REQUIRED)
    target_link_libraries(airplay_crypto INTERFACE OpenSSL::Crypto)
    target_compile_definitions(airplay_crypto INTERFACE OPENSSL_API_COMPAT=0x10101000L)
    return()
endif()
include(${CMAKE_CURRENT_LIST_DIR}/Dependencies.cmake)
airplay_dependency(boringssl boringssl_source)
function(airplay_add_boringssl source)
    # Function scope keeps these settings out of the including project.
    set(BUILD_SHARED_LIBS OFF)
    set(BUILD_TESTING OFF)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
    # iOS makes executables bundles; BoringSSL installs its unused bssl tool
    # without a bundle destination.
    set(CMAKE_MACOSX_BUNDLE OFF)
    if(WIN32)
        # Windows assembly needs NASM; pairing and stream ciphers are cheap in C.
        set(OPENSSL_NO_ASM ON)
    endif()
    add_subdirectory("${source}" "${CMAKE_BINARY_DIR}/boringssl" EXCLUDE_FROM_ALL)
endfunction()
airplay_add_boringssl("${boringssl_source}")
# UxPlay encodes keys with BIO_f_base64, which BoringSSL keeps in decrepit.
target_link_libraries(airplay_crypto INTERFACE decrepit crypto)
