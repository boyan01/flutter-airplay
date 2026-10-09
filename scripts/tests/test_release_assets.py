#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).resolve().parents[1] / 'release_assets.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_changelog_selects_exact_version_and_normalizes_continuations(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'ROOT', Path(directory)):
            (Path(directory) / 'CHANGELOG.md').write_text(
                '# Changelog\n\n## 1.2.4\n### 中文\n- 下个版本。\n### English\n- Next release.\n'
                '\n## 1.2.3\n### English\n- Improve mirroring\n  and recovery.\n### 中文\n- 改进投屏与恢复。\n'
                '\n## 1.2.2\n### 中文\n- 旧版。\n### English\n- Old release.\n')
            self.assertEqual(release.changelog_entry('1.2.3'),
                             '### 中文\n- 改进投屏与恢复。\n\n### English\n- Improve mirroring and recovery.')

    def test_changelog_rejects_missing_duplicate_or_empty_language_sections(self):
        invalid = ('## 1.2.4\n',
                   '## 1.2.3\n### 中文\n- 修复。\n',
                   '## 1.2.3\n### 中文\n- 修复。\n### English\n',
                   '## 1.2.3\n### 中文\n- \n### English\n- Fix.\n',
                   '## 1.2.3\n### 中文\nFix.\n### English\n- Fix.\n',
                   '## 1.2.3\n### 中文\n- 修复。\n### 中文\n- 重复。\n### English\n- Fix.\n',
                   '## 1.2.3\n### 中文\n- 修复。\n### English\n- Fix.\n## 1.2.3\n')
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'ROOT', Path(directory)):
            path = Path(directory) / 'CHANGELOG.md'
            self.assertEqual(release.changelog_entry('1.2.3', required=False), '')
            with self.assertRaises(ValueError):
                release.changelog_entry('1.2.3')
            for text in invalid:
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    release.changelog_entry('1.2.3')
            path.write_text('## 1.2.4\n')
            self.assertEqual(release.changelog_entry('1.2.3', required=False), '')

    def test_tag_without_changelog_stops_before_signing_or_history(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'ROOT', Path(directory)), \
                patch.object(release, 'version', return_value='1.2.3'), \
                patch.object(release, 'signing_config') as signing, \
                patch.object(release, 'previous_version_check') as history, \
                patch.dict(os.environ, {'RELEASE_EVENT': 'push', 'RELEASE_REF_TYPE': 'tag', 'RELEASE_TAG': 'v1.2.3'}):
            with self.assertRaisesRegex(ValueError, 'CHANGELOG'):
                release.metadata()
            signing.assert_not_called()
            history.assert_not_called()
            with self.assertRaisesRegex(ValueError, 'CHANGELOG'), patch.object(release, 'gh') as command:
                release.publish()
            command.assert_not_called()

    def test_tags_are_strict_and_match(self):
        release.validate_tag('v1.2.3', '1.2.3')
        for tag in ('1.2.3', 'v1.2.4', 'v01.2.3', 'v1.2.3-rc.1', 'v1.2.3+4', 'v1.2.3\n', 'v1.2.3;echo hacked'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, '1.2.3')

    def test_metadata_allows_build_only_refs_but_validates_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.flutter-version').write_text('3.47.2\n')
            (root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
            (root / 'CHANGELOG.md').write_text('## 1.2.3\n### 中文\n- 改进投屏。\n### English\n- Improve mirroring.\n')
            output = root / 'output'
            with patch.object(release, 'ROOT', root), patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'signing_config'), patch.object(release, 'previous_version_check'):
                for event, ref_type, tag, succeeds in (
                    ('pull_request', 'branch', '2/merge', True),
                    ('workflow_dispatch', 'branch', 'feat/release', True),
                    ('workflow_dispatch', 'tag', 'v1.2.4', False),
                    ('push', 'tag', 'v1.2.3', True),
                    ('push', 'tag', 'v1.2.4', False),
                ):
                    with patch.dict(os.environ, {'RELEASE_EVENT':event, 'RELEASE_REF_TYPE':ref_type,
                                                'RELEASE_TAG':tag, 'GITHUB_OUTPUT':str(output)}):
                        if succeeds:
                            release.metadata()
                        else:
                            with self.assertRaises(ValueError):
                                release.metadata()
            self.assertNotIn('feat/release', output.read_text())

    def test_version_validates_windows_and_android_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version in ('1.2.3', '1.2.3+0', '1.2.3+65536', '65536.1.2+3', '1.2.3-rc.1+4'):
                (root / 'pubspec.yaml').write_text('version: ' + version + '\n')
                with self.subTest(version=version), self.assertRaises(ValueError):
                    release.version(root)
            (root / 'pubspec.yaml').write_text('version: 1.2.3+42\n')
            self.assertEqual(release.version(root), '1.2.3')

    def fill(self, root, signed):
        directory = root / 'build/release-assets'
        directory.mkdir(parents=True)
        for name in release.asset_names('1.2.3', signed):
            (directory / name).write_bytes(b'package fixture')
        return directory

    def test_macos_dmg_is_required_even_without_android_signing(self):
        names = release.asset_names('1.2.3', False)
        self.assertIn('Flutter-AirPlay-1.2.3-macos-arm64.dmg', names)
        with tempfile.TemporaryDirectory() as directory:
            assets = self.fill(Path(directory), False)
            (assets / 'Flutter-AirPlay-1.2.3-macos-arm64.dmg').unlink()
            with self.assertRaises(ValueError):
                release.collect(assets, '1.2.3', False)

    def test_collection_exact_assets_and_checksums(self):
        for signed in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                assets = self.fill(root, signed)
                result = release.collect(assets, '1.2.3', signed)
                self.assertEqual(len(result), 7 if signed else 6)
                self.assertEqual(len(result[-1].read_text().splitlines()), len(result) - 1)
                with self.assertRaises(ValueError):
                    release.collect(assets, '1.2.3', signed)  # Reject stale/extra inputs.

    def test_rejects_missing_empty_or_extra_assets(self):
        for case in ('missing', 'empty', 'extra', 'symlink'):
            with tempfile.TemporaryDirectory() as directory:
                assets = self.fill(Path(directory), False)
                item = next(assets.iterdir())
                if case == 'missing':
                    item.unlink()
                elif case == 'empty':
                    item.write_bytes(b'')
                elif case == 'symlink':
                    item.unlink()
                    item.symlink_to(next(assets.iterdir()))
                else:
                    (assets / 'unsigned.apk').write_bytes(b'no')
                with self.assertRaises(ValueError):
                    release.collect(assets, '1.2.3', False)

    def publish_fixture(self, root):
        self.fill(root, False)
        (root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
        (root / 'CHANGELOG.md').write_text('## 1.2.3\n### 中文\n- 改进投屏。\n### English\n- Improve mirroring.\n')
        return patch.dict(os.environ, {'RELEASE_TAG': 'v1.2.3', 'RELEASE_SHA': 'a' * 40,
                                      'ANDROID_SIGNED': 'false', 'GITHUB_STEP_SUMMARY': str(root / 'summary'),
                                      'SPARKLE_PUBLIC_KEY': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='})

    def test_failed_upload_never_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root), patch.object(release, 'validate_appcast'):
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh') as gh:
                    gh.side_effect = [json.dumps({'object': {'type':'commit', 'sha':'a'*40}}), '[[]]', '', OSError('upload failed')]
                    with self.assertRaises(OSError):
                        release.publish()
                    self.assertFalse(any('--draft=false' in call.args for call in gh.call_args_list))

    def test_refuses_already_published_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root), patch.object(release, 'validate_appcast'):
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh', side_effect=[json.dumps({'object':{'type':'commit','sha':'a'*40}}), json.dumps([[{'tag_name':'v1.2.3','draft':False}]])]) as gh:
                    with self.assertRaises(ValueError):
                        release.publish()
                    self.assertEqual(gh.call_count, 2)

    def test_draft_resume_safety_and_upload_readback(self):
        for case in ('resume', 'wrong-commit', 'unknown-asset', 'bad-upload', 'moved-after-upload'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.publish_fixture(root), patch.object(release, 'ROOT', root), patch.object(release, 'validate_appcast'):
                    checks = []
                    def gh(*args):
                        if args[0] == 'api':
                            if '/git/' in args[1]:
                                checks.append(True)
                                sha = 'b'*40 if case == 'moved-after-upload' and len(checks) == 2 else 'a'*40
                                return json.dumps({'object':{'type':'commit','sha':sha}})
                            return json.dumps([[{'tag_name':'v1.2.3','draft':True,
                                'target_commitish':'b'*40 if case == 'wrong-commit' else 'a'*40,
                                'assets':[{'name':'unexpected.exe'}] if case == 'unknown-asset' else []}]])
                        if args[1] == 'view':
                            assets = [{'name':p.name,'size':p.stat().st_size} for p in (root/'build/release-assets').iterdir()]
                            if case == 'bad-upload':
                                assets[0]['size'] += 1
                            return json.dumps({'assets':assets})
                        return ''
                    with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh', side_effect=gh) as command:
                        if case == 'resume':
                            release.publish()
                            self.assertEqual(command.call_args.args, ('release','edit','v1.2.3','--draft=false','--latest','--tag','v1.2.3','--verify-tag'))
                        else:
                            with self.assertRaises(ValueError):
                                release.publish()
                            self.assertFalse(any('--draft=false' in call.args for call in command.call_args_list))
                        self.assertFalse(any(call.args[:2] == ('release','create') for call in command.call_args_list))

    def test_newer_release_during_upload_keeps_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root), \
                    patch.object(release, 'validate_appcast'), \
                    patch.object(release, 'previous_version_check', side_effect=[None, ValueError('build must increase')]):
                def gh(*args):
                    if args[0] == 'api':
                        if '/git/' in args[1]:
                            return json.dumps({'object':{'type':'commit','sha':'a'*40}})
                        return '[[]]'
                    if args[1] == 'view':
                        return json.dumps({'assets':[{'name':p.name,'size':p.stat().st_size} for p in (root/'build/release-assets').iterdir()]})
                    return ''
                with patch.object(release, 'gh', side_effect=gh) as command, self.assertRaisesRegex(ValueError, 'increase'):
                    release.publish()
                self.assertTrue(any(call.args[:2] == ('release','upload') for call in command.call_args_list))
                self.assertFalse(any('--draft=false' in call.args for call in command.call_args_list))

    def test_remote_tag_peels_and_rejects_changed_commit(self):
        ref = {'object': {'type':'tag', 'sha':'b'*40}}
        commit = {'object': {'type':'commit', 'sha':'a'*40}}
        with patch.object(release, 'gh', side_effect=map(json.dumps, [ref, commit])):
            release.verify_remote_tag('v1.2.3', 'a'*40)
        with patch.object(release, 'gh', return_value=json.dumps(commit)):
            with self.assertRaises(ValueError):
                release.verify_remote_tag('v1.2.3', 'c'*40)
        with patch.object(release, 'gh', side_effect=OSError('deleted tag')):
            with self.assertRaises(OSError):
                release.verify_remote_tag('v1.2.3', 'a'*40)

    def test_success_publishes_only_after_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root), patch.object(release, 'validate_appcast'):
                bodies = []
                def gh(*args):
                    if '--notes-file' in args:
                        bodies.append(Path(args[args.index('--notes-file') + 1]).read_text())
                    if args[0] == 'api':
                        if '/git/' in args[1]:
                            return json.dumps({'object':{'type':'commit','sha':'a'*40}})
                        return '[[]]'
                    if args[1] == 'view':
                        return json.dumps({'assets':[{'name':p.name,'size':p.stat().st_size} for p in (root/'build/release-assets').iterdir()]})
                    return ''
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh', side_effect=gh) as command:
                    release.publish()
                    self.assertTrue(bodies[0].startswith('### 中文\n- 改进投屏。\n\n### English\n- Improve mirroring.'))
                    self.assertIn('### Downloads and installation', bodies[0])
                    self.assertEqual(command.call_args.args, ('release','edit','v1.2.3','--draft=false','--latest','--tag','v1.2.3','--verify-tag'))
                self.assertIn('Android APK omitted', (root/'summary').read_text())


if __name__ == '__main__':
    unittest.main()
