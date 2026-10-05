#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

# Run during the final Xcode embedding phase, before application signing.
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$resources/build-time.txt"
