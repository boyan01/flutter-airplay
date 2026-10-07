#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo 'macOS packaging requires an Apple Silicon Mac.' >&2; exit 1;
}
version="$(python3 -c 'from scripts.release_assets import version; print(version())')"
flutter pub get --enforce-lockfile
# The Xcode build prepares the native player through ensure_native.py.
flutter build macos --release
output="$project_root/build/distribution/macos"
app="$output/Flutter AirPlay.app"
dmg="$output/Flutter-AirPlay-$version-macos-arm64.dmg"
mkdir -p "$output"
# Replace only this script's generated staging copy.
rm -rf "$app"
ditto "$project_root/build/macos/Build/Products/Release/Flutter AirPlay.app" "$app"
mkdir -p "$app/Contents/Resources/licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/licenses/"
cp vendor/UxPlay/UPSTREAM.md "$app/Contents/Resources/licenses/UxPlay-UPSTREAM.md"
# Sign inside-out, then verify the final bundle before it enters the image.
python3 scripts/audit_macos.py --sign "$app"
staging="$(mktemp -d "$output/dmg-stage.XXXXXX")"
mountpoint="$(mktemp -d "$output/dmg-mount.XXXXXX")"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then hdiutil detach "$mountpoint" || return; fi
    rm -rf "$staging"
    rmdir "$mountpoint"
}
trap cleanup EXIT
ditto "$app" "$staging/Flutter AirPlay.app"
ln -s /Applications "$staging/Applications"
hdiutil create -ov -format UDZO -fs HFS+ -volname 'Flutter AirPlay' -srcfolder "$staging" "$dmg"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$dmg"
mounted=true
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]]
# Verify the drag-to-Applications copy at a relocated path containing spaces.
ditto "$mountpoint/Flutter AirPlay.app" "$staging/Installed App/Flutter AirPlay.app"
python3 scripts/audit_macos.py --smoke "$staging/Installed App/Flutter AirPlay.app"
hdiutil detach "$mountpoint"
mounted=false
(cd "$output" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS)
printf 'Application: %s\nDisk image: %s\n' "$app" "$dmg"
