#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build and package a complete Linux x64 Flutter Release bundle.

Run on the target distribution (release CI uses Ubuntu 24.04). dpkg-shlibdeps
reads the installed distribution's symbol metadata; it must not silently guess
Ubuntu dependency names for binaries built on a different distribution.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "flutter-airplay"
BINARY = "flutter_airplay"
APP_ID = "tech.soit.flutterairplay"
HOMEPAGE = "https://github.com/boyan01/flutter-airplay"
INSTALL_DIR = Path("usr/lib") / PACKAGE
JAVA_HOME = "/usr/lib/jvm/default-java"
REQUIRED_FILES = (
    BINARY,
    "lib/libflutter_linux_gtk.so",
    "lib/libairplay_player.so",
    "lib/libcnativeapi.so",
    "lib/libapp.so",
    "data/icudtl.dat",
    "data/flutter_assets/AssetManifest.bin",
    "data/flutter_assets/NOTICES.Z",
    "data/flutter_assets/version.json",
)


def version_from_pubspec(root):
    """Reject ambiguous versions rather than mislabeling a release artifact."""
    declarations = re.findall(r"^version:[^\n]*$", (root / "pubspec.yaml").read_text(), re.M)
    if len(declarations) != 1:
        raise ValueError("pubspec.yaml must contain exactly one top-level version")
    match = re.fullmatch(
        r"version:\s*((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))"
        r"\+([1-9]\d*)\s*", declarations[0]
    )
    if not match:
        raise ValueError("pubspec.yaml must contain version: major.minor.patch+build")
    return match.group(1), match.group(2)


def require_file(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Missing or empty required file: {path}")


def elf_header(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    if not header.startswith(b"\x7fELF"):
        return None
    if len(header) < 20 or header[4:7] != b"\x02\x01\x01":
        raise ValueError(f"Expected a 64-bit little-endian ELF: {path}")
    kind, machine = struct.unpack_from("<HH", header, 16)
    if machine != 62 or kind not in (2, 3):
        raise ValueError(f"Expected a Linux x86-64 executable/shared library: {path}")
    return kind


def validate_bundle(root, bundle, version, build_number):
    if not bundle.is_dir():
        raise ValueError(f"Release bundle does not exist: {bundle}. Build without --skip-build.")
    for relative in REQUIRED_FILES:
        require_file(bundle / relative)
    if not os.access(bundle / BINARY, os.X_OK):
        raise ValueError(f"Release executable is not executable: {bundle / BINARY}")
    for relative in REQUIRED_FILES[:5]:
        if elf_header(bundle / relative) is None:
            raise ValueError(f"Required executable/library is not ELF: {relative}")
    # AOT libapp.so is required above, so a Debug bundle cannot pass as Release.
    info = json.loads((bundle / "data/flutter_assets/version.json").read_text())
    if not isinstance(info, dict) or (info.get("version"), info.get("build_number")) != (version, build_number):
        raise ValueError("Bundle version/build number does not match pubspec.yaml. Rebuild without --skip-build.")
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "linux/NOTICE",
                 f"linux/icons/{APP_ID}.png", f"linux/{APP_ID}.desktop",
                 "vendor/UxPlay/UPSTREAM.md", "vendor/alac/UPSTREAM.md"):
        require_file(root / name)
    licenses = root / "assets/licenses"
    if not licenses.is_dir() or not any(licenses.iterdir()):
        raise ValueError("Missing source license assets")
    for source in sorted(licenses.rglob("*")):
        if source.is_file():
            require_file(source)
            bundled = bundle / "data/flutter_assets/assets/licenses" / source.relative_to(licenses)
            require_file(bundled)
            if source.read_bytes() != bundled.read_bytes():
                raise ValueError(f"Stale bundled license: {source.name}. Rebuild without --skip-build.")
    bundle_root = bundle.resolve()
    for path in bundle.rglob("*"):
        if path.is_symlink():
            target = path.resolve()
            if Path(os.readlink(path)).is_absolute() or not target.is_relative_to(bundle_root) or not target.exists():
                raise ValueError(f"Bundle contains an absolute, escaping or dangling symlink: {path}")
        elif not path.is_dir() and not path.is_file():
            raise ValueError(f"Bundle contains an unsupported special file: {path}")
        elif path.is_file():
            elf_header(path)  # Reject a mixed-architecture plugin/native asset.


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def stage_bundle(root, bundle, destination):
    # Copy the whole tree, including native assets and plugin shared libraries.
    shutil.copytree(bundle, destination, symlinks=True)
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, destination / name)
    notices = destination / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copytree(root / "assets/licenses", notices / "assets", dirs_exist_ok=True)
    shutil.copy2(root / "linux/NOTICE", notices / "linux-NOTICE")
    for vendor in ("UxPlay", "alac"):
        shutil.copy2(root / f"vendor/{vendor}/UPSTREAM.md", notices / f"{vendor}-UPSTREAM.md")
    # Include desktop integration even for an older otherwise-valid bundle.
    desktop = destination / f"share/applications/{APP_ID}.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / f"linux/{APP_ID}.desktop", desktop)
    icon = destination / f"share/icons/hicolor/512x512/apps/{APP_ID}.png"
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / f"linux/icons/{APP_ID}.png", icon)
    for path in destination.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
    destination.chmod(0o755)


def extra_runtime_dependencies(binaries):
    """Account for unversioned external libraries skipped by dpkg-shlibdeps."""
    bundled_names = {path.name for path in binaries}
    dependencies = set()
    for binary in binaries:
        dynamic = run(["objdump", "-p", str(binary)], text=True, stdout=subprocess.PIPE).stdout
        needed = re.findall(r"^\s*NEEDED\s+(\S+)", dynamic, re.M)
        for name in needed:
            if not name.endswith(".so") or name in bundled_names:
                continue
            if name != "libjvm.so":
                raise ValueError(f"Undeclared unversioned system library {name} needed by {binary}")
            paths = re.findall(r"^\s*(?:RPATH|RUNPATH)\s+(\S+)", dynamic, re.M)
            search = ":".join(paths).split(":")
            expected = JAVA_HOME + "/lib/server"
            if expected not in search or any(p.startswith("/") and p != expected for p in search):
                raise ValueError(
                    "JNI runtime embeds a nonportable Java path. Remove the Linux Release "
                    f"CMake cache and rebuild with JAVA_HOME={JAVA_HOME} (default-jdk-headless)."
                )
            # Ubuntu 24.04 default-jre-headless owns /usr/lib/jvm/default-java
            # and depends on OpenJDK 21; libjvm has no versioned SONAME/shlibs.
            dependencies.add("default-jre-headless")
    return sorted(dependencies)


def derive_dependencies(work, package_root, app):
    """Scan every ELF, including dlopened native assets, without running them."""
    debian = work / "debian"
    (debian / "control").write_text(
        f"Source: {PACKAGE}\nSection: video\nPriority: optional\n"
        f"Maintainer: Flutter AirPlay contributors <noreply@github.com>\n\n"
        f"Package: {PACKAGE}\nArchitecture: amd64\nDescription: Flutter AirPlay receiver\n"
    )
    binaries = sorted(path for path in app.rglob("*")
                      if path.is_file() and not path.is_symlink() and elf_header(path) is not None)
    if not binaries:
        raise ValueError("No ELF binaries found in the staged bundle")
    extra = extra_runtime_dependencies(binaries)
    # -S lets dpkg recognize libraries shipped in this same package. Keep normal
    # missing-library/metadata errors fatal; --ignore-missing-info hides broken
    # dependency declarations on release build hosts.
    library_dirs = sorted({path.parent for path in binaries})
    result = run(
        ["dpkg-shlibdeps", "-O", f"-S{package_root}", f"-x{PACKAGE}"]
        + [f"-l{path}" for path in library_dirs]
        + [f"-e{path}" for path in binaries],
        cwd=work, text=True, stdout=subprocess.PIPE,
    )
    fields = [line.removeprefix("shlibs:Depends=") for line in result.stdout.splitlines()
              if line.startswith("shlibs:Depends=")]
    if len(fields) != 1 or not fields[0].strip():
        raise ValueError("dpkg-shlibdeps did not produce runtime dependencies")
    dependencies = fields[0].strip()
    if "\n" in dependencies or "${" in dependencies:
        raise ValueError("Invalid runtime dependency metadata")
    # Discovery uses a system daemon, which is not discoverable from ELF NEEDED.
    return ", ".join([dependencies, "avahi-daemon", *extra])


def write_runtime_readme(app, version, dependencies):
    (app / "README.txt").write_text(
        f"Flutter AirPlay {version} - Linux x64\n\n"
        "This is the complete relocatable Flutter Release bundle. Keep flutter_airplay,\n"
        "data/, lib/ and the remaining files together. Extract to a permanent directory\n"
        "before enabling launch at login. Run ./flutter_airplay from the extracted folder.\n"
        "The executable uses its adjacent lib/ and data/; do not move it on its own.\n\n"
        "Official Linux release builds target Ubuntu 24.04 x86-64. This is not a static\n"
        "or universally portable Linux binary. Other distributions need compatible\n"
        "library ABIs and graphics drivers. Dependencies below are derived from every\n"
        "ELF in this exact bundle using the build distribution's package metadata.\n"
        "A local build on a newer distribution may require newer system libraries.\n\n"
        f"Required runtime packages (Debian dependency syntax):\n{dependencies}\n\n"
        "A working graphical GTK 3 session and OpenGL 3.2+ / OpenGL ES 3+ are required.\n"
        "Avahi and system D-Bus must be running, with a PulseAudio-compatible user audio\n"
        "service (PulseAudio or PipeWire with pipewire-pulse). The Debian package\n"
        "recommends pipewire-pulse | pulseaudio. The app does not configure services\n"
        "or open firewall ports automatically. Allow AirPlay on your trusted LAN.\n\n"
        "For Ubuntu/Debian, prefer installing the matching .deb with:\n"
        f"  sudo apt install ./Flutter-AirPlay-{version}-linux-x64.deb\n"
        "For the tarball, install the runtime packages above using your distribution's\n"
        "package manager. Optional desktop integration is in share/applications/ and\n"
        "share/icons/. Before copying the desktop entry into your user applications\n"
        "directory, change Exec to your permanent absolute flutter_airplay path.\n\n"
        "When default-jre-headless is listed, the bundled JNI native asset requires\n"
        "libjvm.so at /usr/lib/jvm/default-java/lib/server. Preserve that standard\n"
        "Java runtime path on other distributions too. No JDK is needed at runtime.\n\n"
        "GPL-3.0-only: retain LICENSE, THIRD_PARTY_NOTICES.md, licenses/ and Flutter's\n"
        "data/flutter_assets/NOTICES.Z. Corresponding source and build instructions:\n"
        f"  {HOMEPAGE}\n"
        "Use the source archive/commit matching the release; distributors must provide\n"
        "corresponding source as required by the GPL. System libraries are not copied\n"
        "into this package; their distribution packages supply their own notices.\n"
    )


def install_desktop_integration(package_root, app):
    launcher = package_root / "usr/bin/flutter-airplay"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text('#!/bin/sh\nexec /usr/lib/flutter-airplay/flutter_airplay "$@"\n')
    launcher.chmod(0o755)
    applications = package_root / "usr/share/applications"
    applications.mkdir(parents=True, exist_ok=True)
    desktop = (app / f"share/applications/{APP_ID}.desktop").read_text()
    desktop, count = re.subn(r"^Exec=.*$", "Exec=/usr/bin/flutter-airplay", desktop, flags=re.M)
    if count != 1:
        raise ValueError("Desktop entry must contain exactly one Exec field")
    (applications / f"{APP_ID}.desktop").write_text(desktop)
    icons = package_root / "usr/share/icons/hicolor/512x512/apps"
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copy2(app / f"share/icons/hicolor/512x512/apps/{APP_ID}.png", icons)
    docs = package_root / f"usr/share/doc/{PACKAGE}"
    docs.mkdir(parents=True, exist_ok=True)
    shutil.copy2(app / "LICENSE", docs / "copyright")
    shutil.copy2(app / "THIRD_PARTY_NOTICES.md", docs)


def write_control(package_root, version, dependencies):
    control = package_root / "DEBIAN"
    control.mkdir(exist_ok=True)
    # Debian Installed-Size is measured in KiB, rounded up per regular file.
    size = sum((path.stat().st_size + 1023) // 1024 for path in package_root.rglob("*")
               if path.is_file() and not path.is_symlink())
    (control / "control").write_text(
        f"Package: {PACKAGE}\nVersion: {version}\nArchitecture: amd64\n"
        "Section: video\nPriority: optional\n"
        "Maintainer: Flutter AirPlay contributors <noreply@github.com>\n"
        f"Homepage: {HOMEPAGE}\nInstalled-Size: {size}\nDepends: {dependencies}\n"
        "Recommends: pipewire-pulse | pulseaudio\n"
        "Description: AirPlay receiver with Flutter controls and native playback\n"
        " Receive AirPlay audio and video on a Linux desktop. Requires a graphical\n"
        " session, system Avahi/D-Bus and a PulseAudio-compatible audio service.\n"
    )
    control.chmod(0o755)
    (control / "control").chmod(0o644)


def archive_bundle(app, archive, name):
    def portable_owner(member):
        member.uid = member.gid = 0
        member.uname = member.gname = "root"
        return member
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as output:
        output.add(app, arcname=name, filter=portable_owner)


def package(root, skip_build=False):
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        raise ValueError("Linux packaging requires a Linux x86-64 build host")
    version, build_number = version_from_pubspec(root)
    for tool in ("dpkg-deb", "dpkg-shlibdeps", "objdump"):
        if shutil.which(tool) is None:
            raise ValueError(f"Missing {tool}; install dpkg-dev and binutils on the build host")
    if not skip_build:
        # Hosted CI's JAVA_HOME otherwise points at a runner-only Temurin path.
        env = dict(os.environ, JAVA_HOME=JAVA_HOME)
        run(["flutter", "build", "linux", "--release"], cwd=root, env=env)
    bundle = root / "build/linux/x64/release/bundle"
    validate_bundle(root, bundle, version, build_number)
    output = root / "build/distribution/linux"
    output.mkdir(parents=True, exist_ok=True)
    name = f"Flutter-AirPlay-{version}-linux-x64"
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output) as temporary:
        work = Path(temporary)
        package_root = work / "debian" / PACKAGE
        # dpkg-shlibdeps recognizes the DEBIAN boundary for same-package libs.
        (package_root / "DEBIAN").mkdir(parents=True)
        app = package_root / INSTALL_DIR
        stage_bundle(root, bundle, app)
        dependencies = derive_dependencies(work, package_root, app)
        write_runtime_readme(app, version, dependencies)
        install_desktop_integration(package_root, app)
        write_control(package_root, version, dependencies)
        deb = work / f"{name}.deb"
        archive = work / f"{name}-bundle.tar.gz"
        archive_bundle(app, archive, name)
        run(["dpkg-deb", "--root-owner-group", "--build", str(package_root), str(deb)])
        products = (deb, archive)
        hashes = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in products)
        (work / "SHA256SUMS").write_text(hashes)
        for path in (*products, work / "SHA256SUMS"):
            path.replace(output / path.name)
    return [output / f"{name}.deb", output / f"{name}-bundle.tar.gz"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Package a validated existing Release bundle")
    args = parser.parse_args()
    try:
        for artifact in package(ROOT, args.skip_build):
            print(artifact)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Linux packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
