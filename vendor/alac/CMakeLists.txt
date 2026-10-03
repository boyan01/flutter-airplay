# SPDX-License-Identifier: GPL-3.0-only
add_library(alac_decoder STATIC ALACDecoder.cpp ALACBitUtilities.c EndianPortable.c ag_dec.c dp_dec.c matrix_dec.c)
target_include_directories(alac_decoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(alac_decoder PRIVATE TARGET_RT_LITTLE_ENDIAN=1)
target_compile_options(alac_decoder PRIVATE -fwrapv -fno-strict-aliasing)
set_target_properties(alac_decoder PROPERTIES POSITION_INDEPENDENT_CODE ON)
