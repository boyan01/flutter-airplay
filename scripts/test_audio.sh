#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$project_root/build/audio-tests"
mkdir -p "$test_root/plugins"
for plugin in coreelements app libav audioconvert audioresample level volume audiotestsrc playback autodetect videoparsersbad; do
  ln -sf "/opt/homebrew/lib/gstreamer-1.0/libgst${plugin}.dylib" "$test_root/plugins/"
done
export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_PLUGIN_PATH_1_0="$test_root/plugins"
export GST_REGISTRY_1_0="$test_root/registry.bin"
export GST_REGISTRY_FORK=no
export GST_DEBUG=1
# pkg-config supplies compiler flags; there is no shell evaluation of its output.
read -r -a gst_cflags <<< "$(pkg-config --cflags gstreamer-app-1.0)"
read -r -a gst_libs <<< "$(pkg-config --libs gstreamer-app-1.0)"
clang -I "$project_root/build/uxplay-src/renderers" "${gst_cflags[@]}" "$project_root/native/audio-tests/main.c" "$project_root/build/uxplay-src/lib/logger.c" "${gst_libs[@]}" -o "$test_root/audio-tests"
"$test_root/audio-tests"
