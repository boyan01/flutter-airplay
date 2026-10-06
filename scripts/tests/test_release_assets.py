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
    def test_tags_are_strict_and_match(self):
        release.validate_tag('v1.2.3', '1.2.3')
        for tag in ('1.2.3', 'v1.2.4', 'v01.2.3', 'v1.2.3-rc.1', 'v1.2.3+4', 'v1.2.3\n', 'v1.2.3;echo hacked'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, '1.2.3')

    def test_metadata_allows_build_only_refs_but_validates_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.flutter-version').write_text('3.47.2\n')
            output = root / 'output'
            with patch.object(release, 'ROOT', root), patch.object(release, 'version', return_value='1.2.3'):
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

    def test_collection_exact_assets_and_checksums(self):
        for signed in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                assets = self.fill(root, signed)
                result = release.collect(assets, '1.2.3', signed)
                self.assertEqual(len(result), 5 if signed else 4)
                self.assertEqual(len(result[-1].read_text().splitlines()), len(result) - 1)
                with self.assertRaises(ValueError):
                    release.collect(assets, '1.2.3', signed)  # Reject stale/extra inputs.

    def test_rejects_missing_empty_or_extra_assets(self):
        for case in ('missing', 'empty', 'extra'):
            with tempfile.TemporaryDirectory() as directory:
                assets = self.fill(Path(directory), False)
                item = next(assets.iterdir())
                if case == 'missing':
                    item.unlink()
                elif case == 'empty':
                    item.write_bytes(b'')
                else:
                    (assets / 'unsigned.apk').write_bytes(b'no')
                with self.assertRaises(ValueError):
                    release.collect(assets, '1.2.3', False)

    def publish_fixture(self, root):
        self.fill(root, False)
        (root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
        return patch.dict(os.environ, {'RELEASE_TAG': 'v1.2.3', 'RELEASE_SHA': 'a' * 40,
                                      'ANDROID_SIGNED': 'false', 'GITHUB_STEP_SUMMARY': str(root / 'summary')})

    def test_failed_upload_never_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root):
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh') as gh:
                    gh.side_effect = [json.dumps({'object': {'type':'commit', 'sha':'a'*40}}), '[[]]', '', OSError('upload failed')]
                    with self.assertRaises(OSError):
                        release.publish()
                    self.assertFalse(any('--draft=false' in call.args for call in gh.call_args_list))

    def test_refuses_already_published_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.publish_fixture(root), patch.object(release, 'ROOT', root):
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh', side_effect=[json.dumps({'object':{'type':'commit','sha':'a'*40}}), json.dumps([[{'tag_name':'v1.2.3','draft':False}]])]) as gh:
                    with self.assertRaises(ValueError):
                        release.publish()
                    self.assertEqual(gh.call_count, 2)

    def test_draft_resume_safety_and_upload_readback(self):
        for case in ('resume', 'wrong-commit', 'unknown-asset', 'bad-upload', 'moved-after-upload'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.publish_fixture(root), patch.object(release, 'ROOT', root):
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
                            self.assertEqual(command.call_args.args, ('release','edit','v1.2.3','--draft=false','--tag','v1.2.3','--verify-tag'))
                        else:
                            with self.assertRaises(ValueError):
                                release.publish()
                            self.assertFalse(any('--draft=false' in call.args for call in command.call_args_list))
                        self.assertFalse(any(call.args[:2] == ('release','create') for call in command.call_args_list))

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
            with self.publish_fixture(root), patch.object(release, 'ROOT', root):
                def gh(*args):
                    if args[0] == 'api':
                        if '/git/' in args[1]:
                            return json.dumps({'object':{'type':'commit','sha':'a'*40}})
                        return '[[]]'
                    if args[1] == 'view':
                        return json.dumps({'assets':[{'name':p.name,'size':p.stat().st_size} for p in (root/'build/release-assets').iterdir()]})
                    return ''
                with patch.object(release, 'version', return_value='1.2.3'), patch.object(release, 'gh', side_effect=gh) as command:
                    release.publish()
                    self.assertEqual(command.call_args.args, ('release','edit','v1.2.3','--draft=false','--tag','v1.2.3','--verify-tag'))
                self.assertIn('Android APK omitted', (root/'summary').read_text())


if __name__ == '__main__':
    unittest.main()
