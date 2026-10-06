# SPDX-License-Identifier: GPL-3.0-only
import base64
import importlib.util
import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("package_android", Path(__file__).parents[1] / "package_android.py")
android = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android)


class AndroidReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "pubspec.yaml").write_text("name: fixture\nversion: 1.2.3+45\n")
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.output = self.root / "github-output"
        self.summary = self.root / "github-summary"
        self.environment = {
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.summary),
        }
        self.addCleanup(patch.stopall)
        patch.dict(android.os.environ, self.environment, clear=True).start()
        patch.object(android, "ROOT", self.root).start()
        self.signer = patch.object(android, "find_apksigner", return_value="fixture-apksigner").start()
        self.command = patch.object(android.subprocess, "run", side_effect=self.produce).start()
        self.stdout = io.StringIO()
        patch("sys.stdout", self.stdout).start()
        self.keystores = []
        # Inert bytes and values, never a real/generated credential or certificate.
        self.fixture_bytes = b"inert test data, not a keystore"
        self.signing = {
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(self.fixture_bytes).decode("ascii"),
            "ANDROID_KEYSTORE_PASSWORD": "fixture-store-password",
            "ANDROID_KEY_ALIAS": "fixture-key-alias",
            "ANDROID_KEY_PASSWORD": "fixture-key-password",
        }

    @property
    def source(self):
        return self.root / "build/app/outputs/flutter-apk/app-release.apk"

    @property
    def destination(self):
        return self.root / "build/distribution/android/Flutter-AirPlay-1.2.3-android-arm64.apk"

    def produce(self, command, **kwargs):
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["cwd"], self.root)
        self.assertEqual(kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
        self.assertNotIn("shell", kwargs)
        environment = kwargs["env"]
        if command[0] == "flutter":
            self.assertEqual(command, ["flutter", "build", "apk", "--release", "--target-platform", "android-arm64"])
            self.assertNotIn("ANDROID_KEYSTORE_BASE64", environment)
            for name in android.SIGNING_NAMES[1:]:
                self.assertEqual(environment[name], self.signing[name])
                self.assertNotIn(self.signing[name], command)
            self.assertIn("-Dorg.gradle.daemon=false", environment["GRADLE_OPTS"])
            self.assertIn("-Dorg.gradle.configuration-cache=false", environment["GRADLE_OPTS"])
            path = Path(environment["AIRPLAY_ANDROID_KEYSTORE_PATH"])
            self.assertTrue(path.is_relative_to(self.runner_temp))
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.read_bytes(), self.fixture_bytes)
            self.keystores.append(path)
            self.source.parent.mkdir(parents=True, exist_ok=True)
            self.source.write_bytes(b"fixture APK")
        else:
            self.assertEqual(command, ["fixture-apksigner", "verify", "--verbose", "--print-certs", str(self.source)])
            for name in (*android.SIGNING_NAMES, "AIRPLAY_ANDROID_KEYSTORE_PATH"):
                self.assertNotIn(name, environment)
        return subprocess.CompletedProcess(command, 0, stdout="Signer #1 certificate DN: CN=Release Fixture\n")

    def configure(self):
        os.environ.update(self.signing)

    def assert_cleaned(self):
        self.assertFalse(list(self.runner_temp.iterdir()))
        for path in self.keystores:
            self.assertFalse(path.exists())

    def assert_not_signed(self):
        self.assertEqual(self.output.read_text(), "signed=false\n")
        self.assertFalse(self.destination.exists())

    def assert_no_secrets_logged(self):
        logged = self.stdout.getvalue() + self.summary.read_text()
        for value in self.signing.values():
            self.assertNotIn(value, logged)

    def test_absent_secrets_skip_without_building(self):
        self.assertEqual(android.main(), 0)
        self.command.assert_not_called()
        self.signer.assert_not_called()
        self.assertIn("No APK was packaged", self.summary.read_text())
        self.assert_not_signed()
        self.assert_cleaned()

    def test_partial_configuration_fails_closed(self):
        for missing in android.SIGNING_NAMES:
            with self.subTest(missing=missing):
                self.configure()
                os.environ.pop(missing)
                self.output.unlink(missing_ok=True)
                self.assertEqual(android.main(), 1)
                self.assertIn(missing, self.summary.read_text())
                self.assert_not_signed()
        self.command.assert_not_called()
        self.assert_cleaned()
        self.assert_no_secrets_logged()

    def test_invalid_base64_is_not_logged_or_written(self):
        self.configure()
        for encoded in ("not base64!", self.signing["ANDROID_KEYSTORE_BASE64"] + "\n", "\N{SNOWMAN}"):
            with self.subTest(encoded=encoded):
                os.environ["ANDROID_KEYSTORE_BASE64"] = encoded
                self.output.unlink(missing_ok=True)
                self.assertEqual(android.main(), 1)
                self.assert_not_signed()
                self.assertNotIn(encoded, self.stdout.getvalue())
        self.command.assert_not_called()
        self.assert_cleaned()

    def test_success_packages_verified_versioned_apk_and_cleans_key(self):
        self.configure()
        self.assertEqual(android.main(), 0)
        self.assertEqual(self.command.call_count, 2)
        self.assertEqual(self.destination.read_bytes(), b"fixture APK")
        self.assertEqual(self.output.read_text(),
                         "signed=false\napk=build/distribution/android/Flutter-AirPlay-1.2.3-android-arm64.apk\nsigned=true\n")
        self.assertEqual(len(self.keystores), 1)
        self.assert_cleaned()
        self.assert_no_secrets_logged()

    def test_build_failure_cleans_key_and_withholds_tool_output(self):
        self.configure()

        def fail(command, **kwargs):
            self.produce(command, **kwargs)
            raise subprocess.CalledProcessError(1, command, output=" ".join(self.signing.values()))

        self.command.side_effect = fail
        self.assertEqual(android.main(), 1)
        self.assert_not_signed()
        self.assert_cleaned()
        self.assert_no_secrets_logged()

    def test_signature_verification_failure_cleans_key_without_packaging(self):
        self.configure()

        def fail(command, **kwargs):
            if command[0] != "flutter":
                raise subprocess.CalledProcessError(1, command, output="not signed")
            return self.produce(command, **kwargs)

        self.command.side_effect = fail
        self.assertEqual(android.main(), 1)
        self.assert_not_signed()
        self.assert_cleaned()

    def test_debug_certificate_is_rejected(self):
        self.configure()

        def debug(command, **kwargs):
            self.produce(command, **kwargs)
            return subprocess.CompletedProcess(command, 0,
                                               stdout="Signer #1 certificate DN: C=US, O=Android, CN=Android Debug\n")

        self.command.side_effect = debug
        self.assertEqual(android.main(), 1)
        self.assertIn("Android Debug certificate", self.summary.read_text())
        self.assert_not_signed()
        self.assert_cleaned()

    def test_missing_new_apk_does_not_package_stale_output(self):
        self.configure()
        for path in (self.source, self.destination):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"stale APK")
        self.command.side_effect = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, stdout="")
        self.assertEqual(android.main(), 1)
        self.assertEqual(self.command.call_count, 1)
        self.assert_not_signed()
        self.assert_cleaned()

    def test_copy_failure_cleans_key(self):
        self.configure()

        def partial_copy(source, target):
            target.write_bytes(b"incomplete APK")
            raise OSError("fixture failure")

        with patch.object(android.shutil, "copy2", side_effect=partial_copy):
            self.assertEqual(android.main(), 1)
        self.assert_not_signed()
        self.assert_cleaned()
        self.assertFalse(list(self.destination.parent.iterdir()))

    def test_unavailable_flutter_cleans_key_without_packaging(self):
        self.configure()
        self.command.side_effect = FileNotFoundError("fixture executable missing")
        self.assertEqual(android.main(), 1)
        self.assert_not_signed()
        self.assert_cleaned()

    def test_invalid_version_fails_before_building(self):
        self.configure()
        (self.root / "pubspec.yaml").write_text("version: ../../../invalid\n")
        self.assertEqual(android.main(), 1)
        self.command.assert_not_called()
        self.assert_not_signed()
        self.assert_cleaned()


class ApkSignerDiscoveryTest(unittest.TestCase):
    def test_prefers_newest_stable_sdk_build_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            for version in ("9.0.0", "36.0.0", "35.0.0", "37.0.0-rc1"):
                signer = sdk / "build-tools" / version / "apksigner"
                signer.parent.mkdir(parents=True)
                signer.touch()
                signer.chmod(0o700)
            with patch.dict(android.os.environ, {"ANDROID_HOME": str(sdk)}, clear=True):
                self.assertEqual(android.find_apksigner(), str(sdk / "build-tools/36.0.0/apksigner"))

    def test_missing_signer_is_a_safe_error(self):
        with patch.dict(android.os.environ, {}, clear=True), patch.object(android.shutil, "which", return_value=None):
            with self.assertRaisesRegex(android.PackagingError, "apksigner is required"):
                android.find_apksigner()


if __name__ == "__main__":
    unittest.main()
