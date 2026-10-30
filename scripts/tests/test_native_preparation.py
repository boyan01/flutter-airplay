# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
import hashlib
import io
import json
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
        for file in ("native/dependencies.lock.json", "scripts/build_receiver.sh", "ios/scripts/build_native.sh",
                     "native/apple/CMakeLists.txt", "native/CMakeLists.txt", "native/playback/player.cpp"):
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("original")
        # The lychee_player plugin's framework, where Xcode puts it.
        self.products = self.make_products()
        self.products_env = patch.dict(native.os.environ, {"BUILT_PRODUCTS_DIR": str(self.products)})
        self.products_env.start()
        self.addCleanup(self.products_env.stop)
        toolchain = patch.object(native, "host_toolchain", return_value="Xcode fixture")
        toolchain.start()
        self.addCleanup(toolchain.stop)
        self.output = self.root / "build/macos-native/libairplay_player.dylib"
        self.build = patch.object(native.subprocess, "run", side_effect=self.produce)
        self.command = self.build.start()
        self.addCleanup(self.build.stop)
        # __file__ is an input inside the checkout.
        self.script = patch.object(native, "__file__", str(self.root / "scripts/build_receiver.sh"))
        self.script.start()
        self.addCleanup(self.script.stop)

    def make_products(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        header = Path(directory.name) / "lychee.framework/Headers/lychee.h"
        header.parent.mkdir(parents=True)
        header.write_bytes(b"#define LYCHEE_API_VERSION 14")
        return Path(directory.name)

    def produce(self, *args, **kwargs):
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_bytes(b"built")

    def test_first_build_and_unchanged_reuse(self):
        native.ensure("macos")
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 1)

    def test_lychee_api_change_rebuilds(self):
        native.ensure("macos")
        header = self.products / "lychee.framework/Headers/lychee.h"
        header.write_bytes(b"#define LYCHEE_API_VERSION 15")
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 2)

    def test_missing_lychee_framework_fails(self):
        with patch.dict(native.os.environ, {"BUILT_PRODUCTS_DIR": ""}):
            with self.assertRaises(SystemExit):
                native.ensure("macos")

    def test_source_change_rebuilds(self):
        native.ensure("macos")
        (self.root / "native/playback/player.cpp").write_text("changed")
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 2)

    def test_host_and_test_changes_reuse_product(self):
        native.ensure("macos")
        for name in ("native/apple/ReceiverHost.swift", "native/tests/ffi/receiver_control_test.cpp", "native/tests/fixture.bin"):
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("changed")
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 1)

    def test_platform_backends_only_affect_applicable_products(self):
        manifest = self.root / "build/native-preparation"
        manifest.mkdir(parents=True, exist_ok=True)
        for target in ("macos", "ios"):
            (manifest / f"{target}-sources.txt").write_text("native/playback\nnative/backends/apple\n")
        before = {target: native.inputs(target) for target in ("macos", "ios")}
        backend = self.root / "native/backends/windows/video.cpp"
        backend.parent.mkdir(parents=True, exist_ok=True)
        backend.write_text("Windows backend changed")
        for target, fingerprint in before.items():
            self.assertEqual(native.inputs(target), fingerprint)
        backend = self.root / "native/backends/apple/video.mm"
        backend.parent.mkdir(parents=True, exist_ok=True)
        backend.write_text("Apple backend changed")
        for target, fingerprint in before.items():
            self.assertNotEqual(native.inputs(target), fingerprint)

    def test_deleted_and_modified_artifacts_rebuild(self):
        native.ensure("macos")
        self.output.unlink()
        native.ensure("macos")
        self.output.write_bytes(b"stale")
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 3)

    def test_failed_build_is_retried(self):
        native.ensure("macos")
        (self.root / "native/playback/player.cpp").write_text("changed")
        self.command.side_effect = subprocess.CalledProcessError(1, "builder")
        with self.assertRaises(subprocess.CalledProcessError):
            native.ensure("macos")
        self.assertFalse((self.root / "build/native-preparation/macos.json").exists())
        self.command.side_effect = self.produce
        native.ensure("macos")
        self.assertEqual(self.command.call_count, 3)

    def test_success_without_outputs_does_not_cache(self):
        self.command.side_effect = None
        with self.assertRaises(SystemExit):
            native.ensure("macos")
        self.assertFalse((self.root / "build/native-preparation/macos.json").exists())

    def test_xcode_environment_does_not_mix_platform_targets(self):
        values = {"IPHONEOS_DEPLOYMENT_TARGET": "18.5", "XROS_DEPLOYMENT_TARGET": "1.3",
                  "MACOSX_DEPLOYMENT_TARGET": "15.6", "SDKROOT": "/iphone-sdk",
                  "DEVELOPER_DIR": "/selected-xcode", "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf"}
        with patch.dict(native.os.environ, values):
            for target in ("ios", "macos"):
                environment = native.native_environment(target)
                self.assertFalse(any(key.endswith("_DEPLOYMENT_TARGET") for key in environment))
                self.assertNotIn("SDKROOT", environment)
                self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT", environment)
                self.assertEqual(environment["DEVELOPER_DIR"], "/selected-xcode")
            self.assertEqual(native.os.environ["SDKROOT"], "/iphone-sdk")


if __name__ == "__main__":
    unittest.main()
