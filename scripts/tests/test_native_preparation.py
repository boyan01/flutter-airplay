# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ensure_native", Path(__file__).parents[1] / "ensure_native.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativePreparationTest(unittest.TestCase):
    def setUp(self):
        native.platform.machine()  # Cache Windows platform probing before mocking the builder.
        self.host = patch.object(native.platform, "system", return_value="Linux")
        self.host.start()
        self.addCleanup(self.host.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root_patch = patch.object(native, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        for file in ("android/dependencies.lock.json", "android/gradle.properties",
                     "android/scripts/build_native.sh", "native/player/player.cpp"):
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("original")
        self.output = self.root / "android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so"
        self.build = patch.object(native.subprocess, "run", side_effect=self.produce)
        self.command = self.build.start()
        self.addCleanup(self.build.stop)
        # __file__ is an input inside the checkout.
        self.script = patch.object(native, "__file__", str(self.root / "android/scripts/build_native.sh"))
        self.script.start()
        self.addCleanup(self.script.stop)

    def produce(self, *args, **kwargs):
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_bytes(b"built")

    def test_first_build_and_unchanged_reuse(self):
        native.ensure("android")
        native.ensure("android")
        self.assertEqual(self.command.call_count, 1)

    def test_source_change_rebuilds(self):
        native.ensure("android")
        (self.root / "native/player/player.cpp").write_text("changed")
        native.ensure("android")
        self.assertEqual(self.command.call_count, 2)

    def test_deleted_and_modified_artifacts_rebuild(self):
        native.ensure("android")
        self.output.unlink()
        native.ensure("android")
        self.output.write_bytes(b"stale")
        native.ensure("android")
        self.assertEqual(self.command.call_count, 3)

    def test_failed_build_is_retried(self):
        native.ensure("android")
        (self.root / "native/player/player.cpp").write_text("changed")
        self.command.side_effect = subprocess.CalledProcessError(1, "builder")
        with self.assertRaises(subprocess.CalledProcessError):
            native.ensure("android")
        self.assertFalse((self.root / "build/native-preparation/android.json").exists())
        self.command.side_effect = self.produce
        native.ensure("android")
        self.assertEqual(self.command.call_count, 3)

    def test_success_without_outputs_does_not_cache(self):
        self.command.side_effect = None
        with self.assertRaises(SystemExit):
            native.ensure("android")
        self.assertFalse((self.root / "build/native-preparation/android.json").exists())

    def test_dependency_change_clears_only_generated_cache(self):
        native.prepare_dependencies("android")
        cache = self.root / "android/.cache/crypto-arm64-v8a-test"
        cache.mkdir(parents=True)
        native.prepare_dependencies("android")
        self.assertTrue(cache.is_dir())
        (self.root / "android/dependencies.lock.json").write_text("new pin")
        native.prepare_dependencies("android")
        self.assertFalse(cache.exists())
        self.assertTrue((self.root / "native/player/player.cpp").is_file())


if __name__ == "__main__":
    unittest.main()
