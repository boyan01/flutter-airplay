#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cmake -S "$root/linux/tests" -B "$root/build/linux-native" -G Ninja -DCMAKE_BUILD_TYPE=Debug "$@"
cmake --build "$root/build/linux-native" --parallel
ctest --test-dir "$root/build/linux-native" --output-on-failure
