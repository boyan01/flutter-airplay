#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare the Apple native player from Xcode builds, reusing verified outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import contextlib
import platform

ROOT = Path(__file__).resolve().parents[1]


def native_environment(target):
    environment = os.environ.copy()
    # Xcode exports minimum versions for several platforms at once. Native
    # scripts select their own SDKs and deployment targets (both iOS slices).
    for key in list(environment):
        if key.endswith("_DEPLOYMENT_TARGET") or key in (
                "SDKROOT", "SWIFT_DEBUG_INFORMATION_FORMAT", "SWIFT_DEBUG_INFORMATION_VERSION"):
            environment.pop(key)
    return environment


def host_toolchain(target):
    return subprocess.check_output(["xcodebuild", "-version"], text=True,
                                   env=native_environment(target)).strip()


@contextlib.contextmanager
def build_lock(target):
    import fcntl
    folder = ROOT / "build/native-preparation"
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / f"{target}.lock").open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def digest(paths):
    result = hashlib.sha256()
    for path in sorted(paths):
        result.update(str(path.relative_to(ROOT)).encode())
        result.update(path.read_bytes())
    return result.hexdigest()


def lychee_header(target, environment):
    """The lychee_player plugin's header, from the framework Xcode built."""
    header = Path(environment.get("BUILT_PRODUCTS_DIR", "")) / "lychee.framework/Headers/lychee.h"
    if not header.is_absolute() or not header.is_file():
        raise SystemExit(f"{target}: build through Flutter; the native player links the lychee_player plugin's core.")
    return header


def inputs(target):
    paths = {Path(__file__), ROOT / "native/dependencies.lock.json"}
    paths.update(ROOT / name for name in ("native/CMakeLists.txt", "native/apple/CMakeLists.txt"))
    manifest = ROOT / f"build/native-preparation/{target}-sources.txt"
    if manifest.is_file():
        folders = manifest.read_text().splitlines()
        paths.add(manifest)
    else:
        # Bootstrap conservatively; CMake exports the selected product roots on
        # the first build. Never infer compilation from a filename prefix.
        folders = ["native/include", "native/receiver", "native/protocol", "native/playback",
                   "native/ffi", "native/backends", "native/cmake", "native/compat", "vendor"]
    if target == "macos":
        paths.add(ROOT / "scripts/build_receiver.sh")
    else:
        folders += ["ios/scripts"]
    for folder in folders:
        source_root = ROOT / folder
        if not source_root.resolve().is_relative_to(ROOT.resolve()):
            raise SystemExit(f"Native input manifest escapes the checkout: {folder}")
        for path in source_root.rglob("*"):
            if path.is_file() and not any(part in (".git", "__pycache__") for part in path.parts):
                paths.add(path)
    # Resolve host SDK changes as well as source/configuration changes.
    native_env = native_environment(target)
    environment = {key: native_env.get(key, "") for key in
                   ("DEVELOPER_DIR", "SDKROOT")}
    tools = {}
    for name in ("cmake", "python3", "dart"):
        executable = shutil.which(name)
        if executable:
            tools[name] = (executable, Path(executable).stat().st_mtime_ns)
    tools["host"] = host_toolchain(target)
    # The core's API; a rebuilt plugin core with the same API needs no relink.
    environment["lychee"] = hashlib.sha256(lychee_header(target, native_env).read_bytes()).hexdigest()
    return digest(paths) + json.dumps([environment, tools, platform.machine()], sort_keys=True)


def outputs(target):
    if target == "macos":
        paths = [ROOT / "build/macos-native/libairplay_player.dylib"]
    else:
        folder = ROOT / "build/ios-native/AirplayPlayer.xcframework"
        paths = [folder / "Info.plist"]
        for slice_name in ("ios-arm64", "ios-arm64-simulator"):
            paths += [folder / slice_name / "libAirplayPlayer.a",
                      folder / slice_name / "Headers/player.h",
                      folder / slice_name / "Headers/receiver.h",
                      folder / slice_name / "Headers/receiver_ffi.h"]
    return paths if all(path.is_file() for path in paths) else []


def ensure(target):
    stamp = ROOT / f"build/native-preparation/{target}.json"
    source_hash = inputs(target)
    artifacts = outputs(target)
    try:
        previous = json.loads(stamp.read_text())
    except (OSError, ValueError):
        previous = {}
    if artifacts and previous == {"inputs": source_hash, "outputs": digest(artifacts)}:
        print(f"{target}: native artifacts are current", flush=True)
        return
    # Remove the success marker before building: a failed build must be retried.
    stamp.unlink(missing_ok=True)
    print(f"{target}: preparing native player", flush=True)
    script = "scripts/build_receiver.sh" if target == "macos" else "ios/scripts/build_native.sh"
    subprocess.run(["bash", str(ROOT / script)], cwd=ROOT, check=True, env=native_environment(target))
    artifacts = outputs(target)
    if not artifacts:
        raise SystemExit(f"{target}: native build did not produce all required artifacts")
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps({"inputs": inputs(target), "outputs": digest(artifacts)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("macos", "ios"))
    args = parser.parse_args()
    with build_lock(args.target):
        ensure(args.target)
