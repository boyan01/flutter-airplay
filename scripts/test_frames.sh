#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$project_root/build/frame-tests"
mkdir -p "$test_root/plugins"
for plugin in coreelements app videotestsrc videoconvertscale x264 libav videoparsersbad playback; do
  ln -sf "/opt/homebrew/lib/gstreamer-1.0/libgst${plugin}.dylib" "$test_root/plugins/"
done
export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_PLUGIN_PATH_1_0="$test_root/plugins"
export GST_REGISTRY_1_0="$test_root/registry.bin"
export GST_REGISTRY_FORK=no
read -r -a gst_cflags <<< "$(pkg-config --cflags gstreamer-app-1.0 gstreamer-video-1.0)"
read -r -a gst_libs <<< "$(pkg-config --libs gstreamer-app-1.0 gstreamer-video-1.0)"
clang -I "$project_root/build/uxplay-src/renderers" "${gst_cflags[@]}" "$project_root/native/frame-tests/producer.c" "$project_root/build/uxplay-src/renderers/receiver_frames.c" "$project_root/native/sync-tests/video_fixture.c" "$project_root/build/uxplay-src/lib/logger.c" "${gst_libs[@]}" -o "$test_root/frame-producer"
swiftc "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/macos/Runner/FrameSocketServer.swift" "$project_root/native/frame-tests/main.swift" -o "$test_root/frame-tests"
"$test_root/frame-tests" "$test_root/frame-producer"

swiftc -emit-library -emit-module -module-name FlutterMacOS "$project_root/native/texture-tests/FlutterMacOS.swift" -o "$test_root/libFlutterMacOS.dylib"
swiftc -I "$test_root" -L "$test_root" -lFlutterMacOS -Xlinker -rpath -Xlinker "$test_root" "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/macos/Runner/FrameSocketServer.swift" "$project_root/macos/Runner/FrameTexture.swift" "$project_root/native/texture-tests/main.swift" -o "$test_root/texture-tests"
"$test_root/texture-tests" "$test_root/frame-producer"
