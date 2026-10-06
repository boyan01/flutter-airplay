# SPDX-License-Identifier: GPL-3.0-only
"""Small contracts for the standard Flutter/Gradle Android release path."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AndroidSigningContractTest(unittest.TestCase):
    def test_gradle_uses_environment_without_debug_fallback(self):
        gradle = (ROOT / 'android/app/build.gradle.kts').read_text()
        for name in ('AIRPLAY_ANDROID_KEYSTORE_PATH', 'ANDROID_KEYSTORE_PASSWORD',
                     'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'):
            self.assertIn(name, gradle)
        self.assertIn('System.getenv', gradle)
        self.assertIn('else null', gradle)
        self.assertNotIn('signingConfigs.getByName("debug")', gradle)
        self.assertIn('dependsOn(prepareNativePlayer, copySharedLicenses)', gradle)

    def test_ci_invokes_flutter_directly_and_keeps_key_outside_workspace(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertIn('run: flutter build apk --release --target-platform android-arm64', workflow)
        self.assertIn('"$RUNNER_TEMP/airplay-release.keystore"', workflow)
        self.assertIn('umask 077', workflow)
        self.assertNotIn('package_android.py', workflow)
        self.assertIn('if: github.event_name != \'pull_request\'', workflow)
        self.assertIn('apksigner" verify --print-certs', workflow)


if __name__ == '__main__':
    unittest.main()
