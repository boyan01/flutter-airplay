#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
: "${GRADLE_BIN:?Set GRADLE_BIN to the configured Gradle executable}"
output="$repo/build/android-video-tests"
evidence="$repo/artifacts/android"
mkdir -p "$output/src/main/java/io/github/jqssun/airplay/renderer" "$evidence"
cp "$repo/android/app/src/main/kotlin/io/github/jqssun/airplay/renderer/VideoPipeline.kt" \
   "$repo/android/app/src/main/kotlin/io/github/jqssun/airplay/renderer/EglCore.kt" \
   "$output/src/main/java/io/github/jqssun/airplay/renderer/"
cp "$repo/android/tests/video/VideoPipelineRegression.kt" "$output/src/main/java/"
python3 - "$repo" "$output" "${ANDROID_HOME:-$HOME/Library/Android/sdk}" <<'PY'
from pathlib import Path
import re, sys
repo, output, sdk = map(Path, sys.argv[1:])
version = re.search(r'id\("com.android.application"\) version "([^"]+)"',
                    (repo / 'android/settings.gradle.kts').read_text()).group(1)
(output / 'local.properties').write_text(f'sdk.dir={sdk}\n')
(output / 'settings.gradle.kts').write_text('''
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "VideoRegression"
''')
(output / 'build.gradle.kts').write_text('''
plugins { id("com.android.application") version "%s" }
android {
    namespace = "io.github.boyan01.video_regression"
    compileSdk = 36
    defaultConfig { applicationId = "io.github.boyan01.video_regression"; minSdk = 26; targetSdk = 36 }
}
''' % version)
(output / 'src/main/AndroidManifest.xml').write_text('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="Video Regression" />
    <instrumentation android:name=".VideoPipelineRegression" android:targetPackage="io.github.boyan01.video_regression" />
</manifest>
''')
PY
"$GRADLE_BIN" -p "$output" assembleDebug > "$evidence/video-regression-build.log" 2>&1
adb install -r "$output/build/outputs/apk/debug/VideoRegression-debug.apk" \
    > "$evidence/video-regression-install.log" 2>&1
trap 'adb uninstall io.github.boyan01.video_regression > /dev/null 2>&1 || true' EXIT
adb shell am instrument -w io.github.boyan01.video_regression/.VideoPipelineRegression \
    | tee "$evidence/video-regression-result.txt"
python3 - "$evidence/video-regression-result.txt" <<'PY'
from pathlib import Path
import sys
result = Path(sys.argv[1]).read_text()
if 'INSTRUMENTATION_CODE: 0' not in result or 'verdict=PASS:' not in result:
    raise SystemExit('Video pixel regression failed; see artifacts/android/video-regression-result.txt')
PY
