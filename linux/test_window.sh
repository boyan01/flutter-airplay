#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for command in xvfb-run dbus-run-session openbox xdotool python3; do
  command -v "$command" >/dev/null || { echo "Missing window test dependency: $command" >&2; exit 1; }
done
bundle="${1:-$root/build/linux/x64/debug/bundle}"
xvfb-run -a dbus-run-session -- python3 "$root/linux/tests/window_drag_test.py" "$bundle/flutter_airplay"
