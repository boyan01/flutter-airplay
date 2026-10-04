#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$project_root/build/ffmpeg-video-tests"
mkdir -p "$output"
pkg-config --exists libavcodec libavutil libswscale || {
    echo 'Install FFmpeg 6+ development libraries and pkg-config first.' >&2; exit 1;
}
flags=(-std=c++17)
if [[ ${FFMPEG_SANITIZE:-OFF} == ON ]]; then
    flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
fi
"$project_root/linux/tests/generate_video_fixtures.sh" "$output/fixtures"
"${CXX:-c++}" "${flags[@]}" -I "$project_root/native/player" -I "$project_root/native/player-tests" \
    $(pkg-config --cflags libavcodec libavutil libswscale) \
    "$project_root/native/player/linux_video.cpp" "$project_root/native/player/ffmpeg_video.cpp" \
    "$project_root/linux/tests/video_test.cpp" $(pkg-config --libs libavcodec libavutil libswscale) \
    -o "$output/video-tests"
"$output/video-tests" "$output/fixtures"
