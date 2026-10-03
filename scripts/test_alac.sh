#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$project_root/build/alac-tests"
mkdir -p "$output"
flags=(-g -O1 -fwrapv -fno-strict-aliasing -DTARGET_RT_LITTLE_ENDIAN=1 -I "$project_root/vendor/alac")
if [[ "${ALAC_SANITIZE:-OFF}" == ON ]]; then flags+=(-fsanitize=address -fno-omit-frame-pointer); fi
for source in ALACBitUtilities EndianPortable ag_dec dp_dec matrix_dec; do
    clang "${flags[@]}" -c "$project_root/vendor/alac/$source.c" -o "$output/$source.o"
done
clang++ -std=c++17 "${flags[@]}" -c "$project_root/vendor/alac/ALACDecoder.cpp" -o "$output/ALACDecoder.o"
clang++ -std=c++17 "${flags[@]}" -I "$project_root/native/player" -I "$project_root/native/player-tests" \
    "$project_root/native/player-tests/alac_test.cpp" "$output/"*.o -o "$output/alac-tests"
"$output/alac-tests"
