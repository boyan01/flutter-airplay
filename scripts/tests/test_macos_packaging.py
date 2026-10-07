#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('audit_macos', Path(__file__).resolve().parents[1] / 'audit_macos.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MacPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / 'Installed App/Flutter AirPlay.app'
        self.executable = self.app / 'Contents/MacOS/Flutter AirPlay'
        self.frameworks = self.app / 'Contents/Frameworks'
        self.paths = [self.executable, *(self.frameworks / name for name in (
            'libairplay_player.dylib', 'App.framework/App', 'FlutterMacOS.framework/FlutterMacOS'))]
        for path in self.paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        self.info = {'CFBundleExecutable': 'Flutter AirPlay', 'CFBundleIdentifier': 'tech.soit.flutterairplay',
                     'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '4',
                     'NSLocalNetworkUsageDescription': 'Receive', 'NSBonjourServices': ['_airplay._tcp', '_raop._tcp']}
        self.write_info()
        self.assets = self.frameworks / 'App.framework/Resources/flutter_assets'
        for path in (self.root / 'assets/licenses/license.txt', self.assets / 'assets/licenses/license.txt',
                     self.assets / 'NOTICES.Z'):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'license')
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            (self.root / name).write_text('notice')
            target = self.app / 'Contents/Resources/licenses' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('notice')
        (self.root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
        self.entitlements = {'com.apple.security.app-sandbox': False}
        entitlements = self.root / 'macos/Runner/Release.entitlements'
        entitlements.parent.mkdir(parents=True)
        entitlements.write_bytes(plistlib.dumps(self.entitlements))
        self.arch = 'arm64'
        self.dependency = '@rpath/libairplay_player.dylib'
        for patcher in (patch.object(audit, 'ROOT', self.root),
                        patch.object(audit, 'binaries', return_value=self.paths),
                        patch.object(audit, 'output', side_effect=self.output),
                        patch.object(audit.subprocess, 'run'),
                        patch.object(audit.subprocess, 'check_output', return_value=plistlib.dumps(self.entitlements))):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def output(self, *args):
        if args[0].endswith('lipo'):
            return self.arch
        if args[1] == '-l':
            return 'cmd LC_RPATH\ncmdsize 48\npath @executable_path/../Frameworks (offset 12)\n'
        if args[1] == '-D':
            return str(args[2]) + ':\n'
        return f'{args[2]}:\n\t{self.dependency} (compatibility version 1.0.0, current version 1.0.0)\n'

    def test_valid_bundle(self):
        audit.audit(self.app)

    def test_rejects_wrong_architecture(self):
        self.arch = 'x86_64'
        with self.assertRaisesRegex(ValueError, 'No arm64'):
            audit.audit(self.app)

    def test_rejects_external_dependency(self):
        self.dependency = '/opt/homebrew/lib/libcrypto.dylib'
        with self.assertRaisesRegex(ValueError, 'Unbundled dependency'):
            audit.audit(self.app)

    def test_rejects_external_rpath_even_with_bundled_fallback(self):
        external = self.root / 'external'
        external.mkdir()
        (external / 'libairplay_player.dylib').write_text('outside')
        listing = (f'cmd LC_RPATH\ncmdsize 48\npath {external} (offset 12)\n'
                   'cmd LC_RPATH\ncmdsize 48\npath @executable_path/../Frameworks (offset 12)\n')
        with patch.object(audit, 'output', return_value=listing), self.assertRaisesRegex(ValueError, 'External or unsupported'):
            audit.rpaths(self.executable, self.app)

    def test_system_runpath_supports_dyld_shared_cache(self):
        with patch.object(audit, 'output', return_value='cmd LC_RPATH\ncmdsize 48\npath /usr/lib/swift (offset 12)\n'):
            self.assertEqual(audit.rpaths(self.executable, self.app), [Path('/usr/lib/swift')])
        self.assertFalse(audit.system_path(Path('/usr/lib/../../opt/homebrew/lib')))

    def test_exact_loader_tokens_are_valid(self):
        self.assertEqual(audit.loader_path('@loader_path', self.executable, self.app), self.executable.parent)
        self.assertEqual(audit.loader_path('@executable_path', self.executable, self.app), self.executable.parent)

    def test_rejects_missing_rpath(self):
        with patch.object(audit, 'rpaths', return_value=[]), self.assertRaisesRegex(ValueError, 'Unbundled dependency'):
            audit.audit(self.app)

    def test_rejects_escaping_and_broken_symlink(self):
        target = self.frameworks / 'libairplay_player.dylib'
        target.unlink()
        outside = self.root / 'outside.dylib'
        outside.write_text('fixture')
        target.symlink_to(outside)
        self.assertFalse(audit.bundled(target, self.app))
        with self.assertRaises(ValueError):
            audit.audit(self.app)
        outside.unlink()
        self.assertFalse(audit.bundled(target, self.app))

    def test_rejects_missing_executable(self):
        self.executable.unlink()
        with self.assertRaisesRegex(ValueError, 'executable missing'):
            audit.audit(self.app)

    def test_rejects_mismatched_version_and_bonjour(self):
        for field, value in [('CFBundleVersion', '5'), ('CFBundleIdentifier', 'other'), ('NSBonjourServices', [])]:
            original = self.info[field]
            self.info[field] = value
            self.write_info()
            with self.subTest(field=field), self.assertRaises(ValueError):
                audit.audit(self.app)
            self.info[field] = original

    def test_rejects_stale_or_missing_licenses(self):
        license = self.assets / 'assets/licenses/license.txt'
        license.write_bytes(b'stale')
        with self.assertRaisesRegex(ValueError, 'license differs'):
            audit.audit(self.app)
        license.unlink()
        with self.assertRaises(FileNotFoundError):
            audit.audit(self.app)

    def test_rejects_changed_entitlements(self):
        with patch.object(audit.subprocess, 'check_output', return_value=plistlib.dumps({})), self.assertRaisesRegex(ValueError, 'entitlements'):
            audit.audit(self.app)

    def test_signs_inside_out_without_deep_signing(self):
        with patch.object(audit.subprocess, 'run') as run:
            audit.sign(self.app)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(all('--deep' not in command for command in commands))
        self.assertEqual(commands[-1][-1], str(self.app))
        self.assertIn('--entitlements', commands[-1])
        self.assertLess(next(i for i, c in enumerate(commands) if c[-1] == str(self.frameworks/'App.framework/App')),
                        next(i for i, c in enumerate(commands) if c[-1] == str(self.frameworks/'App.framework')))


if __name__ == '__main__':
    unittest.main()
