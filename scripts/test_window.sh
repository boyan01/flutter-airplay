#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$project_root/build/window-tests"
framework_root="$project_root/build/macos/Build/Products/Debug"
if [[ ! -d "$framework_root/FlutterMacOS.framework/Headers" ]]; then
  echo 'Build the macOS Debug application first: flutter build macos --debug' >&2
  exit 1
fi
mkdir -p "$test_root"
# Same-file extensions access private test seams without rewriting production code.
cat "$project_root/macos/Runner/MainFlutterWindow.swift" "$project_root/native/window-tests/main.swift" > "$test_root/main.swift"
swiftc -F "$framework_root" -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$framework_root" "$test_root/main.swift" -o "$test_root/window-tests"
# Requires a logged-in macOS GUI session. AppKit performs real fullscreen transitions.
"$test_root/window-tests"
