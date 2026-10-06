#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a verified release APK using an existing, ephemeral signing keystore.

With no signing inputs, report signed=false and omit Android from the release.
Partial or invalid inputs fail closed. This script never creates credentials.
"""
import base64
import binascii
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIGNING_NAMES = (
    "ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
)


class PackagingError(Exception):
    """A safe-to-display error, without tool output or signing values."""


def github_output(name, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"{name}={value}\n")


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(message + "\n")


def release_version():
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$",
                      (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise PackagingError("pubspec.yaml must contain version: major.minor.patch+build.")
    return match[1]


def find_apksigner():
    # Prefer the newest installed stable SDK build-tools over an arbitrary PATH
    # entry. The release workflow installs the project's supported build-tools.
    for name in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        sdk = os.environ.get(name)
        if not sdk:
            continue
        candidates = []
        for path in (Path(sdk) / "build-tools").glob("*/apksigner"):
            if re.fullmatch(r"\d+\.\d+\.\d+", path.parent.name) and os.access(path, os.X_OK):
                candidates.append(path)
        if candidates:
            return str(max(candidates, key=lambda path: tuple(map(int, path.parent.name.split(".")))))
    executable = shutil.which("apksigner")
    if executable:
        return executable
    raise PackagingError("Android SDK apksigner is required to verify the release APK.")


def run_checked(command, environment, stage):
    # Gradle errors can contain signing values. Capture and withhold subprocess
    # output rather than risk printing secrets, even on a failed build.
    try:
        result = subprocess.run(command, cwd=ROOT, env=environment, check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError as error:
        raise PackagingError(
            f"{stage} failed (exit {error.returncode}); tool output withheld to protect signing secrets.") from None
    except OSError:
        raise PackagingError(f"Could not run {stage}; check the installed build tools.") from None
    return result.stdout


def package():
    # This remains false for every skip or failure, including verification.
    github_output("signed", "false")
    signing = {name: os.environ.get(name, "") for name in SIGNING_NAMES}
    if not any(signing.values()):
        report("Android release skipped: signing secrets are not configured. No APK was packaged.")
        return None
    missing = [name for name, value in signing.items() if not value]
    if missing:
        raise PackagingError("Incomplete Android signing configuration; missing: " + ", ".join(missing))
    try:
        keystore_bytes = base64.b64decode(signing["ANDROID_KEYSTORE_BASE64"], validate=True)
    except (ValueError, binascii.Error):
        raise PackagingError("ANDROID_KEYSTORE_BASE64 must be strict, single-line base64.") from None
    if not keystore_bytes:
        raise PackagingError("The decoded Android signing keystore is empty.")

    version = release_version()
    apksigner = find_apksigner()
    source = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
    output = ROOT / "build/distribution/android"
    destination = output / f"Flutter-AirPlay-{version}-android-arm64.apk"
    # A failed/no-op build must not reuse an earlier release APK.
    source.unlink(missing_ok=True)
    destination.unlink(missing_ok=True)
    environment = os.environ.copy()
    environment.pop("ANDROID_KEYSTORE_BASE64", None)
    # Do not persist signing configuration in a reusable Gradle daemon/cache.
    environment["GRADLE_OPTS"] = (environment.get("GRADLE_OPTS", "") +
                                  " -Dorg.gradle.daemon=false -Dorg.gradle.configuration-cache=false")
    report("Building Android arm64 release with the configured signing key.")
    # TemporaryDirectory guarantees cleanup on success and exceptions. On CI it
    # lives outside the checkout and every artifact/cache directory.
    with tempfile.TemporaryDirectory(prefix="airplay-android-signing-",
                                     dir=os.environ.get("RUNNER_TEMP") or None) as temporary:
        keystore = Path(temporary) / "release.keystore"
        descriptor = os.open(keystore, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(keystore_bytes)
        os.chmod(keystore, 0o600)
        environment["AIRPLAY_ANDROID_KEYSTORE_PATH"] = str(keystore)
        run_checked(["flutter", "build", "apk", "--release", "--target-platform", "android-arm64"],
                    environment, "Flutter Android release build")
        if not source.is_file():
            raise PackagingError("Flutter did not produce the expected Android release APK.")
        verification_environment = environment.copy()
        for name in (*SIGNING_NAMES, "AIRPLAY_ANDROID_KEYSTORE_PATH"):
            verification_environment.pop(name, None)
        certificates = run_checked([apksigner, "verify", "--verbose", "--print-certs", str(source)],
                                   verification_environment, "Android APK signature verification")
        for line in certificates.splitlines():
            if "certificate DN:" in line and re.search(
                    r"(?:^|,)\s*CN=Android Debug(?:,|$)", line.split("certificate DN:", 1)[1].strip(), re.IGNORECASE):
                raise PackagingError("Refusing to package an APK signed with an Android Debug certificate.")
        output.mkdir(parents=True, exist_ok=True)
        # Never leave a partly copied APK with a publishable filename.
        with tempfile.NamedTemporaryFile(prefix=destination.name + ".", suffix=".tmp",
                                         dir=output, delete=False) as handle:
            staging = Path(handle.name)
        try:
            shutil.copy2(source, staging)
            staging.replace(destination)
        finally:
            staging.unlink(missing_ok=True)

    github_output("apk", destination.relative_to(ROOT).as_posix())
    github_output("signed", "true")
    report(f"Verified signed Android release APK: {destination.name}")
    return destination


def main():
    try:
        package()
        return 0
    except PackagingError as error:
        report(f"Android release packaging failed: {error}")
    except OSError:
        # File errors may embed environment-controlled paths; avoid echoing them.
        report("Android release packaging failed: unable to access a required file or temporary directory.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
