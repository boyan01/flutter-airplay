#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare native artifacts for the platform build, reusing verified outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import contextlib
import platform
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def prepare_windows_make():
    """Fetch a verified POSIX Make without depending on Flutter build output."""
    entry = json.loads((ROOT / "android/dependencies.lock.json").read_text())["windows-make"]
    folder = ROOT / "windows/.cache/tools"
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / f"make-{entry['version']}.pkg.tar.zst"
    package = archive.read_bytes() if archive.is_file() else b""
    if hashlib.sha256(package).hexdigest() != entry["sha256"]:
        print("Downloading pinned Windows GNU Make...", flush=True)
        with urllib.request.urlopen(entry["url"], timeout=60) as response:
            package = response.read()
        if hashlib.sha256(package).hexdigest() != entry["sha256"]:
            raise SystemExit("Windows GNU Make package SHA-256 mismatch")
        temporary = archive.with_suffix(".download")
        temporary.write_bytes(package)
        temporary.replace(archive)
    # Extract only the executable: archive paths cannot escape the cache.
    # Windows' built-in bsdtar supports the MSYS2 zstd package format.
    tar = str(Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/tar.exe")
    result = subprocess.run([tar, "-xOf", str(archive), "usr/bin/make.exe"],
                            check=True, capture_output=True)
    if not result.stdout:
        raise SystemExit("Windows GNU Make package has no executable")
    executable = folder / "usr/bin/make.exe"
    executable.parent.mkdir(parents=True, exist_ok=True)
    if not executable.is_file() or executable.read_bytes() != result.stdout:
        temporary = executable.with_suffix(".download")
        temporary.write_bytes(result.stdout)
        temporary.replace(executable)
    return executable


def native_environment(target):
    environment = os.environ.copy()
    if target in ("ios", "macos"):
        # Xcode exports minimum versions for several platforms at once. Native
        # scripts select their own SDKs and deployment targets (both iOS slices).
        for key in list(environment):
            if key.endswith("_DEPLOYMENT_TARGET") or key in (
                    "SDKROOT", "SWIFT_DEBUG_INFORMATION_FORMAT", "SWIFT_DEBUG_INFORMATION_VERSION"):
                environment.pop(key)
    return environment


def host_toolchain(target):
    if target in ("ios", "macos"):
        return subprocess.check_output(["xcodebuild", "-version"], text=True,
                                       env=native_environment(target)).strip()
    if target == "windows":
        vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        return subprocess.check_output(
            [str(vswhere), "-latest", "-version", "[17.0,18.0)", "-products", "*",
             "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationVersion"], text=True).strip()
    return ""


@contextlib.contextmanager
def build_lock(target):
    folder = ROOT / "build/native-preparation"
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / f"{target}.lock").open("a+b") as handle:
        if os.name == "nt":
            import msvcrt
            import time
            handle.write(b"\0")
            handle.flush()
            while True:
                handle.seek(0)
                try:
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    time.sleep(0.2)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


def prepare_dependencies(target):
    """Invalidate generated dependency libraries when their pinned inputs change."""
    stamp = ROOT / f"build/native-preparation/{target}-dependencies.txt"
    script = ROOT / ("scripts/build_receiver.sh" if target == "macos" else
                     f"{target}/scripts/build_native." + ("ps1" if target == "windows" else "sh"))
    paths = [ROOT / "android/dependencies.lock.json", script]
    if target == "android":
        paths += [ROOT / "android/gradle.properties"]
    if target == "windows":
        paths += [ROOT / "windows/scripts/build_ffmpeg.sh"]
    fingerprint = digest(paths) + host_toolchain(target)
    if stamp.is_file() and stamp.read_text() == fingerprint:
        return
    patterns = {
        "windows": ["build/windows-deps/crypto", "build/windows-deps/openssl-build",
                    "build/windows-deps/ffmpeg-build", "build/windows-deps/ffmpeg-aac", "build/windows-native"],
        "macos": ["build/macos-crypto", "build/macos-openssl", "build/macos-native"],
        "ios": ["build/ios-crypto-*", "build/ios-openssl-*", "build/ios-native-*"],
        "android": ["android/.cache/crypto-arm64-*", "android/.cache/openssl-arm64-*", "build/android-native-arm64-*"],
    }
    for pattern in patterns[target]:
        for path in ROOT.glob(pattern):
            resolved = path.resolve()
            # Only generated directories inside this checkout may be removed.
            if not resolved.is_relative_to(ROOT.resolve()) or not any(resolved.is_relative_to((ROOT / base).resolve())
                       for base in ("build", "android/.cache")) or path.is_symlink():
                raise SystemExit(f"Refusing to clear dependency cache outside generated directories: {path}")
            shutil.rmtree(resolved)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(fingerprint)


def digest(paths):
    result = hashlib.sha256()
    for path in sorted(paths):
        result.update(str(path.relative_to(ROOT)).encode())
        result.update(path.read_bytes())
    return result.hexdigest()


def inputs(target):
    paths = {Path(__file__), ROOT / "android/dependencies.lock.json"}
    folders = ["native", "vendor", f"{target}/scripts"]
    if target == "android":
        folders += ["android/app/src/main/cpp"]
        paths.add(ROOT / "android/gradle.properties")
    if target == "windows":
        folders += ["windows/cmake", "windows/compat"]
    else:
        folders += ["android/scripts"]
    if target == "macos":
        paths.add(ROOT / "scripts/build_receiver.sh")
    for folder in folders:
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and not any(part in (".git", "__pycache__") for part in path.parts):
                paths.add(path)
    # Resolve host SDK changes as well as source/configuration changes.
    native_env = native_environment(target)
    environment = {key: native_env.get(key, "") for key in
                   ("ANDROID_HOME", "ANDROID_SDK_ROOT", "DEVELOPER_DIR", "SDKROOT")}
    tools = {}
    for name in ("cmake", "python3", "perl"):
        executable = shutil.which(name)
        if executable:
            tools[name] = (executable, Path(executable).stat().st_mtime_ns)
    tools["host"] = host_toolchain(target)
    return digest(paths) + json.dumps([environment, tools, platform.machine()], sort_keys=True)


def outputs(target):
    if target == "windows":
        folder = ROOT / "build/windows-native/Release"
        paths = [folder / "airplay_player.dll", folder / "airplay_player.lib"]
        for component in ("avcodec", "avutil", "swresample", "swscale"):
            matches = list(folder.glob(f"{component}-*.dll"))
            if len(matches) != 1:
                return []
            paths += matches
        paths += [folder / "ffmpeg-licenses/FFmpeg-build-config.txt",
                  folder / "ffmpeg-licenses/COPYING.LGPLv2.1", folder / "ffmpeg-licenses/LICENSE.md"]
    elif target == "macos":
        paths = [ROOT / "build/macos-native/libairplay_player.dylib"]
    elif target == "android":
        paths = [ROOT / "android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so"]
    else:
        folder = ROOT / "build/ios-native/AirplayPlayer.xcframework"
        paths = [folder / "Info.plist"]
        for slice_name in ("ios-arm64", "ios-arm64-simulator"):
            paths += [folder / slice_name / "libAirplayPlayer.a",
                      folder / slice_name / "Headers/player.h"]
    return paths if all(path.is_file() for path in paths) else []


def ensure(target):
    if target == "android" and platform.system() == "Windows":
        raise SystemExit("Android native builds currently require macOS or Linux x86_64; see DEVELOPMENT.md for the supported host toolchain.")
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
    if target == "windows":
        command = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                   str(ROOT / "windows/scripts/build_native.ps1")]
    else:
        script = "scripts/build_receiver.sh" if target == "macos" else f"{target}/scripts/build_native.sh"
        command = ["bash", str(ROOT / script)]
    subprocess.run(command, cwd=ROOT, check=True, env=native_environment(target))
    artifacts = outputs(target)
    if not artifacts:
        raise SystemExit(f"{target}: native build did not produce all required artifacts")
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps({"inputs": source_hash, "outputs": digest(artifacts)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-windows-make", action="store_true")
    parser.add_argument("target", choices=("android", "macos", "ios", "windows"))
    parser.add_argument("--prepare-dependencies", action="store_true")
    args = parser.parse_args()
    if args.prepare_windows_make:
        if args.target != "windows":
            parser.error("--prepare-windows-make requires windows")
        print(prepare_windows_make().resolve())
    elif args.prepare_dependencies:
        prepare_dependencies(args.target)
    else:
        with build_lock(args.target):
            ensure(args.target)
