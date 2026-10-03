#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
player="$project_root/build/macos-native/libairplay_player.dylib"
[[ -f "$player" ]] || { echo 'Build the shared player with ./scripts/build_receiver.sh first.' >&2; exit 1; }
# Xcode incremental builds can retain the previous receiver resource directory.
rm -rf "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/receiver"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$frameworks"
cp "$player" "$frameworks/"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$frameworks/libairplay_player.dylib"
