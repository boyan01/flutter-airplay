#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -d "$repo/build/ios-native/AirplayPlayer.xcframework" ]] || {
    echo 'Run ./ios/scripts/build_native.sh and flutter build ios --simulator --no-codesign first.' >&2; exit 1;
}
destination=${IOS_TEST_DESTINATION:-}
if [[ -z "$destination" ]]; then
    device=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
groups=json.load(sys.stdin)["devices"]
for runtime in sorted(groups, key=lambda key: tuple(map(int,re.findall(r"\d+",key))), reverse=True):
    for device in groups[runtime]:
        if device["name"].startswith("iPad") and device.get("isAvailable"):
            print(device["udid"]); sys.exit(0)
sys.exit("No installed iPad simulator is available")')
    destination="id=$device"
fi
mkdir -p "$repo/artifacts/ios"
result="$repo/artifacts/ios/player-tests.xcresult"
[[ ! -e "$result" ]] || result="$repo/artifacts/ios/player-tests-$(date +%Y%m%d-%H%M%S).xcresult"
cd "$repo"
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$repo/build/ios-tests" \
    -resultBundlePath "$result" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
