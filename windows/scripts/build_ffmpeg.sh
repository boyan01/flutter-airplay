#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
source_dir="$(cygpath -u "$1")"
build_dir="$(cygpath -u "$2")"
prefix="$(cygpath -u "$3")"
make_bin="$(cygpath -u "$4")"
# Use tools from this Bash distribution; Flutter's inherited PATH can put Git
# Bash ahead of MSYS2, mixing incompatible shell quoting and path conversion.
shell_dir="$(dirname "$BASH")"
export PATH="$shell_dir:$PATH"
# Find the MSVC linker before the distribution's Unix link utility.
export PATH="$(dirname "$(command -v cl.exe)"):$PATH"
mkdir -p "$build_dir"
cd "$build_dir"
options=(
    --toolchain=msvc --arch=x86_64 --target-os=win32 --extra-cflags=-MD
    "--prefix=$prefix" --enable-shared --disable-static '--ln_s=cp -f'
    --disable-programs --disable-doc --disable-debug --disable-autodetect
    --disable-everything --enable-decoder=aac,hevc --enable-swscale --disable-x86asm
    --enable-d3d11va --enable-hwaccel=hevc_d3d11va,hevc_d3d11va2
    --disable-avdevice --disable-avfilter --disable-avformat
    --disable-postproc --disable-network
)
"$source_dir/configure" "${options[@]}"
"$make_bin" -r "SHELL=$shell_dir/sh" -j "${NUMBER_OF_PROCESSORS:-4}"
"$make_bin" -r "SHELL=$shell_dir/sh" install
mkdir -p "$prefix/licenses"
cp "$source_dir/COPYING.LGPLv2.1" "$source_dir/LICENSE.md" "$prefix/licenses/"
printf '%s\n' "${options[@]}" > "$prefix/licenses/FFmpeg-build-config.txt"
