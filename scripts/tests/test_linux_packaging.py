# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("package_linux", Path(__file__).parents[1] / "package_linux.py")
linux = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux)


def fake_elf(machine=62):
    return b"\x7fELF\x02\x01\x01" + bytes(9) + struct.pack("<HH", 3, machine) + bytes(44)


@unittest.skipUnless(linux.platform.system() == "Linux", "Linux packaging uses POSIX file semantics")
class LinuxPackagingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airplay package test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "build/linux/x64/release/bundle"
        self.put("pubspec.yaml", "name: flutter_airplay\nversion: 1.2.3+4\n")
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "linux/NOTICE",
                     "vendor/UxPlay/UPSTREAM.md", "vendor/alac/UPSTREAM.md"):
            self.put(name, f"Notice: {name}\n")
        self.put(f"linux/icons/{linux.APP_ID}.png", b"PNG fixture")
        self.put(f"linux/{linux.APP_ID}.desktop", "[Desktop Entry]\nType=Application\n"
                 f"Name=Flutter AirPlay\nExec=flutter_airplay\nIcon={linux.APP_ID}\n")
        for relative in linux.REQUIRED_FILES:
            self.put(self.bundle / relative, fake_elf() if relative in linux.REQUIRED_FILES[:5] else b"asset")
        (self.bundle / linux.BINARY).chmod(0o755)
        self.put(self.bundle / "data/flutter_assets/version.json", json.dumps({"version": "1.2.3", "build_number": "4"}))
        self.put("assets/licenses/UxPlay-GPL-3.0.txt", b"GPL fixture")
        self.put(self.bundle / "data/flutter_assets/assets/licenses/UxPlay-GPL-3.0.txt", b"GPL fixture")
        self.put(self.bundle / "lib/nested/libextra.so.2", fake_elf())
        (self.bundle / "lib/nested/libextra.so").symlink_to("libextra.so.2")
        self.put(self.bundle / "lib/native_assets.json", '{"native_assets": {}}')
        self.put(self.bundle / "data/flutter_assets/custom.bin", b"preserve complete data")

    def put(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)
        return path

    def validate(self):
        linux.validate_bundle(self.root, self.bundle, "1.2.3", "4")

    def test_pubspec_version_drops_only_build_suffix(self):
        self.assertEqual(linux.version_from_pubspec(self.root), ("1.2.3", "4"))

    def test_pubspec_rejects_missing_ambiguous_and_invalid_versions(self):
        for version in ("", "version: 1.2.3", "version: 01.2.3+4", "version: 1.2.3-beta+4",
                        "version: 1.2.3+4\nversion: 9.9.9+9", " version: 1.2.3+4", "version: ../bad+1",
                        "version: 1.2.3+0", "version: '1.2.3+4\"", "version: 1.2.3+04"):
            with self.subTest(version=version):
                self.put("pubspec.yaml", version)
                with self.assertRaisesRegex(ValueError, "pubspec.yaml"):
                    linux.version_from_pubspec(self.root)

    def test_complete_bundle_passes(self):
        self.validate()

    def test_each_required_file_is_mandatory(self):
        for relative in linux.REQUIRED_FILES:
            path = self.bundle / relative
            original = path.read_bytes()
            path.unlink()
            with self.subTest(relative=relative), self.assertRaisesRegex(ValueError, "required file"):
                self.validate()
            path.write_bytes(original)
            if relative == linux.BINARY:
                path.chmod(0o755)

    def test_executable_must_have_execute_bit(self):
        (self.bundle / linux.BINARY).chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            self.validate()

    def test_version_and_build_mismatch_are_rejected(self):
        for info in ({"version": "1.2.2", "build_number": "4"},
                     {"version": "1.2.3", "build_number": "3"}, [], {}):
            self.put(self.bundle / "data/flutter_assets/version.json", json.dumps(info))
            with self.subTest(info=info), self.assertRaisesRegex(ValueError, "version/build"):
                self.validate()

    def test_missing_or_stale_license_assets_are_rejected(self):
        path = self.bundle / "data/flutter_assets/assets/licenses/UxPlay-GPL-3.0.txt"
        path.write_bytes(b"old")
        with self.assertRaisesRegex(ValueError, "Stale bundled license"):
            self.validate()
        path.unlink()
        with self.assertRaisesRegex(ValueError, "required file"):
            self.validate()

    def test_wrong_architecture_in_nested_native_asset_is_rejected(self):
        self.put(self.bundle / "lib/nested/libextra.so.2", fake_elf(183))
        with self.assertRaisesRegex(ValueError, "x86-64"):
            self.validate()

    def test_non_elf_required_library_is_rejected(self):
        self.put(self.bundle / "lib/libapp.so", b"not a release library")
        with self.assertRaisesRegex(ValueError, "not ELF"):
            self.validate()

    def test_absolute_escaping_and_dangling_symlinks_are_rejected(self):
        link = self.bundle / "lib/unsafe.so"
        for target in (str(self.bundle / "lib/libapp.so"), "../../../../../../etc/passwd", "missing.so"):
            link.symlink_to(target)
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "symlink"):
                self.validate()
            link.unlink()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX filesystem required")
    def test_special_file_is_rejected(self):
        os.mkfifo(self.bundle / "pipe")
        with self.assertRaisesRegex(ValueError, "special file"):
            self.validate()

    def test_staging_preserves_full_tree_and_notices(self):
        destination = self.root / "staged"
        linux.stage_bundle(self.root, self.bundle, destination)
        for source in self.bundle.rglob("*"):
            if source.is_file():
                self.assertEqual(source.read_bytes(), (destination / source.relative_to(self.bundle)).read_bytes())
        link = destination / "lib/nested/libextra.so"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "libextra.so.2")
        for relative in ("LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/linux-NOTICE",
                         "licenses/UxPlay-UPSTREAM.md", "licenses/alac-UPSTREAM.md",
                         "licenses/assets/UxPlay-GPL-3.0.txt", f"share/applications/{linux.APP_ID}.desktop",
                         f"share/icons/hicolor/512x512/apps/{linux.APP_ID}.png"):
            self.assertTrue((destination / relative).is_file(), relative)
        self.assertEqual((destination / linux.BINARY).stat().st_mode & 0o777, 0o755)
        self.assertEqual((destination / "LICENSE").stat().st_mode & 0o777, 0o644)

    def test_shlibdeps_scans_every_elf_without_ignoring_missing_dependencies(self):
        work = self.root / "work"
        package_root = work / "debian/flutter-airplay"
        package_root.mkdir(parents=True)
        app = package_root / linux.INSTALL_DIR
        linux.stage_bundle(self.root, self.bundle, app)
        with patch.object(linux, "run", return_value=subprocess.CompletedProcess([], 0, "shlibs:Depends=libc6 (>= 2.38), libgtk-3-0t64\n")) as run:
            deps = linux.derive_dependencies(work, package_root, app)
        self.assertEqual(deps, "libc6 (>= 2.38), libgtk-3-0t64, avahi-daemon")
        command = run.call_args.args[0]
        self.assertNotIn("--ignore-missing-info", command)
        self.assertIn(f"-e{app / 'lib/nested/libextra.so.2'}", command)
        self.assertIn(f"-l{app / 'lib/nested'}", command)
        self.assertIn(f"-S{package_root}", command)
        self.assertNotIn(f"-e{app / 'lib/native_assets.json'}", command)
        self.assertNotIn(f"-e{app / 'lib/nested/libextra.so'}", command)

    def test_empty_dependency_output_is_rejected(self):
        work = self.root / "work"
        package_root = work / "debian/flutter-airplay"
        package_root.mkdir(parents=True)
        for output in ("", "shlibs:Depends=\n", "shlibs:Depends=${unknown}\n"):
            with patch.object(linux, "run", return_value=subprocess.CompletedProcess([], 0, output)):
                with self.subTest(output=output), self.assertRaises(ValueError):
                    linux.derive_dependencies(work, package_root, self.bundle)

    def test_jni_runtime_dependency_uses_distribution_java_path(self):
        dynamic = "  NEEDED libjvm.so\n  RUNPATH /usr/lib/jvm/default-java/lib/server\n"
        with patch.object(linux, "run", return_value=subprocess.CompletedProcess([], 0, dynamic)):
            self.assertEqual(linux.extra_runtime_dependencies([Path("libdartjni.so")]), ["default-jre-headless"])

    def test_jni_rejects_missing_or_runner_only_java_path(self):
        for path in ("", "/opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/21/lib/server",
                     "/opt/java/lib/server:/usr/lib/jvm/default-java/lib/server"):
            dynamic = f"  NEEDED libjvm.so\n  RUNPATH {path}\n"
            with patch.object(linux, "run", return_value=subprocess.CompletedProcess([], 0, dynamic)):
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "nonportable Java path"):
                    linux.extra_runtime_dependencies([Path("libdartjni.so")])

    def test_unknown_unversioned_external_library_is_rejected(self):
        dynamic = "  NEEDED libunknown.so\n"
        with patch.object(linux, "run", return_value=subprocess.CompletedProcess([], 0, dynamic)):
            with self.assertRaisesRegex(ValueError, "Undeclared unversioned"):
                linux.extra_runtime_dependencies([Path("libplugin.so")])
            self.assertEqual(linux.extra_runtime_dependencies([Path("libplugin.so"), Path("libunknown.so")]), [])

    def test_runtime_readme_records_exact_dependencies_and_limitations(self):
        linux.write_runtime_readme(self.bundle, "1.2.3", "libgtk-3-0t64 (>= 3.24), avahi-daemon")
        text = (self.bundle / "README.txt").read_text()
        for expected in ("libgtk-3-0t64 (>= 3.24), avahi-daemon", "Ubuntu 24.04", "./flutter_airplay",
                         "pipewire-pulse", "GPL", "not a static", "corresponding source"):
            self.assertIn(expected, text)

    def test_debian_integration_uses_the_installed_location(self):
        app = self.root / "package" / linux.INSTALL_DIR
        linux.stage_bundle(self.root, self.bundle, app)
        linux.install_desktop_integration(self.root / "package", app)
        self.assertIn('exec /usr/lib/flutter-airplay/flutter_airplay "$@"',
                      (self.root / "package/usr/bin/flutter-airplay").read_text())
        desktop = (self.root / f"package/usr/share/applications/{linux.APP_ID}.desktop").read_text()
        self.assertIn("Exec=/usr/bin/flutter-airplay\n", desktop)
        self.assertNotIn(str(self.root), desktop)
        self.assertTrue((self.root / "package/usr/share/doc/flutter-airplay/copyright").is_file())

    def test_archive_has_one_top_directory_and_preserves_symlinks(self):
        archive = self.root / "bundle.tar.gz"
        linux.archive_bundle(self.bundle, archive, "Flutter-AirPlay-1.2.3-linux-x64")
        with tarfile.open(archive) as product:
            members = product.getmembers()
            self.assertTrue(all(member.name.split("/")[0] == "Flutter-AirPlay-1.2.3-linux-x64" for member in members))
            self.assertTrue(all(member.uid == member.gid == 0 for member in members))
            link = product.getmember("Flutter-AirPlay-1.2.3-linux-x64/lib/nested/libextra.so")
            self.assertTrue(link.issym())
            self.assertEqual(link.linkname, "libextra.so.2")

    def test_failed_dependency_analysis_keeps_previous_artifacts(self):
        old = self.put("build/distribution/linux/Flutter-AirPlay-1.2.3-linux-x64.deb", b"previous release")
        with patch.object(linux.platform, "system", return_value="Linux"), \
                patch.object(linux.platform, "machine", return_value="x86_64"), \
                patch.object(linux.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(linux, "derive_dependencies", side_effect=ValueError("missing metadata")):
            with self.assertRaisesRegex(ValueError, "missing metadata"):
                linux.package(self.root, skip_build=True)
        self.assertEqual(old.read_bytes(), b"previous release")
        self.assertEqual(sorted(path.name for path in old.parent.iterdir()), [old.name])

    def test_missing_build_tool_has_actionable_error(self):
        with patch.object(linux.platform, "system", return_value="Linux"), \
                patch.object(linux.platform, "machine", return_value="x86_64"), \
                patch.object(linux.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "install dpkg-dev and binutils"):
                linux.package(self.root, skip_build=True)

    def test_default_build_invokes_flutter_release(self):
        with patch.object(linux.platform, "system", return_value="Linux"), \
                patch.object(linux.platform, "machine", return_value="x86_64"), \
                patch.object(linux.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(linux, "run") as run, \
                patch.object(linux, "validate_bundle", side_effect=ValueError("test stop")):
            with self.assertRaisesRegex(ValueError, "test stop"):
                linux.package(self.root)
        self.assertEqual(run.call_args.args[0], ["flutter", "build", "linux", "--release"])
        self.assertEqual(run.call_args.kwargs["cwd"], self.root)
        self.assertEqual(run.call_args.kwargs["env"]["JAVA_HOME"], "/usr/lib/jvm/default-java")

    def test_non_linux_or_non_x64_host_is_rejected(self):
        for system, machine in (("Darwin", "x86_64"), ("Linux", "aarch64")):
            with patch.object(linux.platform, "system", return_value=system), \
                    patch.object(linux.platform, "machine", return_value=machine):
                with self.assertRaisesRegex(ValueError, "Linux x86-64"):
                    linux.package(self.root, skip_build=True)

    @unittest.skipUnless(os.name == "posix" and all(shutil.which(tool) for tool in ("dpkg-deb", "dpkg-shlibdeps", "gcc")),
                         "Real Debian packaging integration requires dpkg-dev and gcc")
    def test_real_deb_and_tar_with_compiled_elf_fixture(self):
        if linux.platform.machine().lower() not in ("x86_64", "amd64"):
            self.skipTest("Integration fixture is x86-64")
        source = self.put("fixture.c", '#include <stdio.h>\nint main(void) { puts("package fixture"); return 0; }\n')
        executable = self.root / "fixture"
        subprocess.run(["gcc", str(source), "-o", str(executable)], check=True)
        for path in self.bundle.rglob("*"):
            if path.is_file() and not path.is_symlink() and linux.elf_header(path) is not None:
                shutil.copy2(executable, path)
        # Add a real versioned private dependency, plus an ELF that links to it.
        # This checks that dpkg-shlibdeps does not demand a distribution package
        # for a bundled library with a public-looking versioned SONAME.
        shared_source = self.put("private.c", "int private_value(void) { return 42; }\n")
        private = self.bundle / "lib/libprivate.so.1"
        subprocess.run(["gcc", "-shared", "-fPIC", "-Wl,-soname,libprivate.so.1",
                        str(shared_source), "-o", str(private)], check=True)
        (self.bundle / "lib/libprivate.so").symlink_to("libprivate.so.1")
        client_source = self.put("plugin.c", "extern int private_value(void);\nint plugin_value(void) { return private_value(); }\n")
        subprocess.run(["gcc", "-shared", "-fPIC", str(client_source),
                        "-L" + str(private.parent), "-lprivate", "-o", str(self.bundle / "lib/libplugin.so")], check=True)
        # Local metadata makes this test independent of whether the host image
        # has an installed dpkg database (our stripped cloud image does not).
        # The production script does not manufacture or override metadata.
        original = linux.derive_dependencies
        def with_fixture_metadata(work, package_root, app):
            (work / "debian/shlibs.local").write_text("libc 6 libc6 (>= 2.17)\n")
            return original(work, package_root, app)
        with patch.object(linux, "derive_dependencies", side_effect=with_fixture_metadata):
            products = linux.package(self.root, skip_build=True)
        self.assertEqual([p.name for p in products], ["Flutter-AirPlay-1.2.3-linux-x64.deb", "Flutter-AirPlay-1.2.3-linux-x64-bundle.tar.gz"])
        fields = subprocess.check_output(["dpkg-deb", "--field", str(products[0])], text=True)
        for expected in ("Package: flutter-airplay", "Version: 1.2.3", "Architecture: amd64", "Depends: libc6 (>= 2.17), avahi-daemon"):
            self.assertIn(expected, fields)
        extracted = self.root / "extracted"
        subprocess.run(["dpkg-deb", "--extract", str(products[0]), str(extracted)], check=True)
        self.assertEqual(subprocess.check_output([str(extracted / linux.INSTALL_DIR / linux.BINARY)], text=True).strip(), "package fixture")
        self.assertTrue((extracted / linux.INSTALL_DIR / "lib/nested/libextra.so").is_symlink())
        self.assertEqual((extracted / linux.INSTALL_DIR / "data/flutter_assets/custom.bin").read_bytes(), b"preserve complete data")
        with tarfile.open(products[1]) as archive:
            readme = archive.extractfile("Flutter-AirPlay-1.2.3-linux-x64/README.txt").read().decode()
            self.assertIn("libc6 (>= 2.17), avahi-daemon", readme)
        checksums = (products[0].parent / "SHA256SUMS").read_text()
        self.assertEqual(len(checksums.splitlines()), 2)
        for path in products:
            self.assertIn(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}", checksums)


if __name__ == "__main__":
    unittest.main()
