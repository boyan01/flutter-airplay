#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
flutter pub get
./scripts/build_receiver.sh
flutter build macos --release
output="$project_root/build/distribution/macos"
app="$output/Flutter AirPlay.app"
mkdir -p "$output"
# Replace only this script's generated staging copy.
rm -rf "$app"
ditto "$project_root/build/macos/Build/Products/Release/Flutter AirPlay.app" "$app"
# Nested code was signed by Xcode. Re-sign the final application ad-hoc.
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$app"
python3 scripts/audit_macos.py "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Flutter-AirPlay-macos-arm64.zip"
shasum -a 256 "$output/Flutter-AirPlay-macos-arm64.zip" > "$output/SHA256SUMS"
printf 'Application: %s\nArchive: %s\n' "$app" "$output/Flutter-AirPlay-macos-arm64.zip"
