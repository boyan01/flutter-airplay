#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build/native-tests"
swiftc "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/native/tests/main.swift" -o "$project_root/build/native-tests/receiver-tests"
"$project_root/build/native-tests/receiver-tests" "$@"
