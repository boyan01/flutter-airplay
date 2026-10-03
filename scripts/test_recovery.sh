#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$project_root/build/audio-tests"
# Share the isolated synthetic test plugins, never the running app's registry.
"$project_root/scripts/test_audio.sh"
export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_PLUGIN_PATH_1_0="$test_root/plugins"
export GST_REGISTRY_1_0="$test_root/registry.bin"
export GST_REGISTRY_FORK=no
export GST_DEBUG=1
read -r -a gst_cflags <<< "$(pkg-config --cflags gstreamer-app-1.0)"
read -r -a gst_libs <<< "$(pkg-config --libs gstreamer-app-1.0)"
clang -I "$project_root/build/uxplay-src/renderers" "${gst_cflags[@]}" "$project_root/native/recovery-tests/main.c" "$project_root/build/uxplay-src/lib/logger.c" "${gst_libs[@]}" -o "$test_root/recovery-tests"
"$test_root/recovery-tests"
