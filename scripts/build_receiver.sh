#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
command -v cmake >/dev/null || { echo 'Install cmake, pkg-config, libplist, openssl@3 and gstreamer first.' >&2; exit 1; }
cmake -S "$project_root/vendor/UxPlay" -B "$project_root/build/uxplay-native" -DNO_MARCH_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$project_root/build/uxplay-native" --parallel "$(sysctl -n hw.logicalcpu)"
mkdir -p "$project_root/native/receiver"
cp "$project_root/build/uxplay-native/uxplay" "$project_root/native/receiver/uxplay"
cp "$project_root/vendor/UxPlay/LICENSE" "$project_root/native/receiver/UxPlay-LICENSE"
echo 'Native receiver ready. Run flutter run -d macos or flutter build macos.'
