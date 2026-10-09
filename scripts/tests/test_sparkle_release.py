#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).resolve().parents[1] / 'release_assets.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
PRIVATE = base64.b64encode(bytes(range(32))).decode()
PUBLIC = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg='
SIGNATURE = base64.b64encode(bytes(64)).decode()


class SparkleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = self.root / 'Flutter AirPlay.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 1.2.3+4\n')
        (self.root / 'CHANGELOG.md').write_text('## 1.2.3\n### 中文\n- 改进投屏。\n### English\n- Improve mirroring.\n')
        self.dmg = self.root / 'Flutter-AirPlay-1.2.3-macos-arm64.dmg'
        self.dmg.write_bytes(b'archive fixture')
        self.info = {'SUPublicEDKey': PUBLIC, 'SUFeedURL': release.FEED_URL,
                     'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '4'}
        self.write_info()
        for patcher in (patch.object(release, 'ROOT', self.root),
                        patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': PRIVATE, 'SPARKLE_PUBLIC_KEY': PUBLIC})):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def make_feed(self):
        with patch.object(release, 'derive_public_key', return_value=PUBLIC), patch.object(release, 'previous_version_check'), \
                patch.object(release, 'sparkle_tool', return_value=Path('/tool/sign_update')), \
                patch.object(release, 'crypto_command', return_value=SIGNATURE.encode()), \
                patch.object(release, 'verify_signature'):
            release.appcast(self.app, self.dmg)
        return self.root / 'appcast.xml'

    def test_android_extension_preserves_macos_metadata_and_shared_notes(self):
        feed = self.make_feed()
        before = release.read_appcast(feed.read_bytes())
        apk = self.root / 'Flutter-AirPlay-1.2.3-android-arm64.apk'
        apk.write_bytes(b'APK fixture')
        release.add_android_appcast(feed, apk, '1.2.3', '4004')
        item, enclosure, short, build = release.read_appcast(feed.read_bytes())
        self.assertEqual((short, build), ('1.2.3', 4))
        self.assertEqual(enclosure.attrib, before[1].attrib)
        self.assertEqual(item.findtext('description'), before[0].findtext('description'))
        android = item.find(f'{{{release.ANDROID_NS}}}android')
        self.assertEqual(android.get('versionCode'), '4004')
        self.assertEqual(android.get('length'), str(apk.stat().st_size))
        self.assertEqual(android.get('sha256'), release.hashlib.sha256(apk.read_bytes()).hexdigest())
        self.assertTrue(android.get('url').endswith(apk.name))
        before_retry = feed.read_bytes()
        release.add_android_appcast(feed, apk, '1.2.3', '4004')
        self.assertEqual(feed.read_bytes(), before_retry)
        with self.assertRaises(ValueError):
            release.add_android_appcast(feed, apk, '1.2.3', '4005')

    def test_android_extension_requires_actual_apk_build(self):
        feed = self.make_feed()
        with self.assertRaises(ValueError):
            release.add_android_appcast(feed, self.root / 'missing.apk', '1.2.3', '')

    def test_appcast_metadata_uses_bundle_build_and_exact_release_url(self):
        feed = self.make_feed()
        item, enclosure, short, build = release.read_appcast(feed.read_bytes())
        self.assertEqual((short, build), ('1.2.3', 4))
        self.assertEqual(enclosure.get('length'), str(self.dmg.stat().st_size))
        self.assertEqual(enclosure.get(f'{{{release.SPARKLE_NS}}}edSignature'), SIGNATURE)
        self.assertEqual(item.findtext(f'{{{release.SPARKLE_NS}}}minimumSystemVersion'), '12.0')
        self.assertIn('/releases/download/v1.2.3/', enclosure.get('url'))
        with patch.object(release, 'verify_signature') as verify:
            release.validate_appcast(feed, self.dmg, '1.2.3', 4, PUBLIC)
            verify.assert_called_once_with(self.dmg, SIGNATURE, PUBLIC)

    def test_appcast_embeds_bilingual_notes_with_safe_text_and_line_breaks(self):
        (self.root / 'CHANGELOG.md').write_text(
            '## 1.2.3\n### 中文\n- 修复 <script> 与 A&B。\n### English\n- Fix <script> and A&B. Keep "sender\'s" name.\n')
        feed = self.make_feed()
        item, _, _, _ = release.read_appcast(feed.read_bytes())
        description = item.findtext('description')
        self.assertIn('<p>中文</p>', description)
        self.assertIn('<p>• 修复 &lt;script&gt; 与 A&amp;B。</p>', description)
        self.assertIn('<p>English</p>', description)
        self.assertIn('"sender\'s"', description)
        self.assertNotIn('<script>', description)
        with patch.object(release, 'verify_signature'):
            release.validate_appcast(feed, self.dmg, '1.2.3', 4, PUBLIC, required_notes=True)
        tree = ET.parse(feed)
        tree.find('./channel/item/description').text = 'Wrong release notes'
        tree.write(feed)
        with patch.object(release, 'verify_signature'), self.assertRaisesRegex(ValueError, 'CHANGELOG'):
            release.validate_appcast(feed, self.dmg, '1.2.3', 4, PUBLIC, required_notes=True)

    def test_local_appcast_allows_missing_notes_but_release_requires_them(self):
        (self.root / 'CHANGELOG.md').unlink()
        item, _, _, _ = release.read_appcast(self.make_feed().read_bytes())
        self.assertIn('See the GitHub release', item.findtext('description'))
        with patch.dict(os.environ, {'AIRPLAY_REQUIRE_UPDATES': 'true'}), \
                patch.object(release, 'signing_config') as signing, self.assertRaisesRegex(ValueError, 'CHANGELOG'):
            release.appcast(self.app, self.dmg)
        signing.assert_not_called()

    def test_metadata_tampering_is_rejected(self):
        for case in ('short', 'build', 'minimum', 'notes', 'url', 'length', 'duplicate', 'invalid-xml'):
            with self.subTest(case=case):
                feed = self.make_feed()
                tree = ET.fromstring(feed.read_bytes())
                item = tree.find('./channel/item')
                enclosure = item.find('enclosure')
                if case in ('short', 'build', 'minimum', 'notes'):
                    name = {'short':'shortVersionString', 'build':'version', 'minimum':'minimumSystemVersion', 'notes':'releaseNotesLink'}[case]
                    item.find(f'{{{release.SPARKLE_NS}}}{name}').text = '99'
                elif case in ('url', 'length'):
                    enclosure.set(case, '99')
                elif case == 'duplicate':
                    tree.find('channel').append(ET.fromstring(ET.tostring(item)))
                feed.write_bytes(b'<' if case == 'invalid-xml' else ET.tostring(tree))
                with self.assertRaises(ValueError), patch.object(release, 'verify_signature'):
                    release.validate_appcast(feed, self.dmg, '1.2.3', 4, PUBLIC)

    def test_bundle_key_feed_or_version_mismatch_stops_before_signing(self):
        for field in self.info:
            original = self.info[field]
            self.info[field] = 'wrong'
            self.write_info()
            with patch.object(release, 'derive_public_key', return_value=PUBLIC), \
                    patch.object(release, 'sparkle_tool') as tool, self.assertRaisesRegex(ValueError, 'bundle'):
                release.appcast(self.app, self.dmg)
            tool.assert_not_called()
            self.info[field] = original

    def test_keyless_bundle_rejects_stale_embedded_public_key(self):
        with self.assertRaisesRegex(ValueError, 'bundle'):
            release.validate_bundle_updates(self.app, '')
        self.info['SUPublicEDKey'] = ''
        self.write_info()
        release.validate_bundle_updates(self.app, '')

    def test_signing_config_missing_invalid_or_mismatched_keys(self):
        for private, public in (('', ''), (PRIVATE, ''), ('', PUBLIC)):
            with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY':private, 'SPARKLE_PUBLIC_KEY':public}):
                self.assertEqual(release.signing_config(), '')
                with self.assertRaisesRegex(ValueError, 'require'):
                    release.signing_config(required=True)
        for private, public in (('not a key', PUBLIC), (PRIVATE, 'not a key'), (PRIVATE + '\n', PUBLIC)):
            with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY':private, 'SPARKLE_PUBLIC_KEY':public}), self.assertRaises(ValueError):
                release.signing_config(required=True)
        with patch.object(release, 'derive_public_key', return_value='wrong'), self.assertRaisesRegex(ValueError, 'does not match'):
            release.signing_config(required=True)

    def test_keychain_signing_uses_account_without_exporting_private_key(self):
        with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': '', 'AIRPLAY_SPARKLE_ACCOUNT': 'flutter-airplay'}), \
                patch.object(release.sys, 'platform', 'darwin'), \
                patch.object(release, 'sparkle_tool', side_effect=lambda name='sign_update': Path('/tool') / name), \
                patch.object(release, 'crypto_command', side_effect=[PUBLIC.encode(), SIGNATURE.encode(), b'']) as command, \
                patch.object(release, 'verify_signature'):
            release.appcast(self.app, self.dmg)
        calls = command.call_args_list
        self.assertEqual(calls[0].args[0], ['/tool/generate_keys', '--account', 'flutter-airplay', '-p'])
        self.assertEqual(calls[1].args[0], ['/tool/sign_update', '--account', 'flutter-airplay', '-p', str(self.dmg)])
        self.assertIsNone(calls[1].kwargs['input'])
        self.assertIsNone(calls[2].kwargs['input'])
        self.assertTrue((self.root / 'appcast.xml').exists())

    def test_keychain_config_rejects_wrong_public_key_and_ambiguous_sources(self):
        with patch.dict(os.environ, {'AIRPLAY_SPARKLE_ACCOUNT': 'flutter-airplay'}), \
                patch.object(release.sys, 'platform', 'darwin'), \
                self.assertRaisesRegex(ValueError, 'either'):
            release.signing_config()
        with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': '', 'AIRPLAY_SPARKLE_ACCOUNT': 'flutter-airplay'}), \
                patch.object(release.sys, 'platform', 'darwin'), \
                patch.object(release, 'sparkle_tool', return_value=Path('/tool/generate_keys')), \
                patch.object(release, 'crypto_command', return_value=base64.b64encode(bytes(32))), \
                self.assertRaisesRegex(ValueError, 'does not match'):
            release.signing_config()

    def test_private_key_never_appears_in_tool_errors_or_child_environment(self):
        result = subprocess.CompletedProcess([], 1, stdout=PRIVATE.encode(), stderr=PRIVATE.encode())
        with patch.object(release.subprocess, 'run', return_value=result) as run:
            with self.assertRaises(ValueError) as error:
                release.crypto_command(['/tool'], input=(PRIVATE + '\n').encode())
        self.assertNotIn(PRIVATE, str(error.exception))
        self.assertNotIn('SPARKLE_PRIVATE_KEY', run.call_args.kwargs['env'])

    def test_previous_feed_requires_strict_build_and_semver_increase(self):
        feed = self.make_feed().read_text()
        previous = {'draft':False, 'prerelease':False, 'tag_name':'v1.2.3',
                    'assets':[{'name':'appcast.xml', 'id':1}]}
        for short, build, succeeds in (('1.2.4', 5, True), ('1.2.4', 4, False), ('1.2.4', 3, False),
                                      ('1.2.3', 5, False), ('1.2.2', 6, False)):
            with self.subTest(short=short, build=build), patch.object(release, 'gh', return_value=feed):
                if succeeds:
                    release.previous_version_check(short, build, [previous])
                else:
                    with self.assertRaisesRegex(ValueError, 'increase'):
                        release.previous_version_check(short, build, [previous])

    def test_bootstrap_uses_old_tag_pubspec_and_does_not_ignore_failures(self):
        previous = {'draft':False, 'tag_name':'v1.2.2', 'assets':[]}
        content = base64.b64encode(b'version: 1.2.2+3\n').decode()
        with patch.object(release, 'gh', return_value=json.dumps({'content':content})) as gh:
            release.previous_version_check('1.2.3', 4, [previous])
            self.assertIn('pubspec.yaml?ref=v1.2.2', gh.call_args.args[1])
        with patch.object(release, 'gh', side_effect=OSError('offline')), self.assertRaises(OSError):
            release.previous_version_check('1.2.3', 4, [previous])
        with patch.object(release, 'gh', return_value=json.dumps({'content':base64.b64encode(b'version: bad').decode()})), self.assertRaises(ValueError):
            release.previous_version_check('1.2.3', 4, [previous])
        release.previous_version_check('1.2.3', 4, [])
        release.previous_version_check('1.2.3', 4, [{'draft':True}])

    def test_tag_metadata_fails_before_output_when_signing_missing(self):
        output = self.root / 'output'
        (self.root / '.flutter-version').write_text('3.47.2\n')
        with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY':'', 'SPARKLE_PUBLIC_KEY':'',
                                    'RELEASE_EVENT':'push', 'RELEASE_REF_TYPE':'tag', 'RELEASE_TAG':'v1.2.3',
                                    'GITHUB_OUTPUT':str(output)}), self.assertRaisesRegex(ValueError, 'require'):
            release.metadata()
        self.assertFalse(output.exists())

    def test_publication_cannot_omit_feed(self):
        assets = self.root / 'release-assets'
        assets.mkdir()
        for name in release.asset_names('1.2.3', False):
            (assets / name).write_bytes(b'asset')
        (assets / 'appcast.xml').unlink()
        with self.assertRaisesRegex(ValueError, 'asset set'):
            release.collect(assets, '1.2.3', False)

    def test_failed_signing_never_produces_appcast(self):
        for output, message in ((b'not-a-signature', 'Base64'), (SIGNATURE.encode(), 'signature validation')):
            with self.subTest(output=output), patch.object(release, 'derive_public_key', return_value=PUBLIC), \
                    patch.object(release, 'sparkle_tool', return_value=Path('/tool/sign_update')), \
                    patch.object(release, 'crypto_command', return_value=output), \
                    patch.object(release, 'verify_signature', side_effect=ValueError('signature validation failed')), \
                    self.assertRaisesRegex(ValueError, message):
                release.appcast(self.app, self.dmg)
            self.assertFalse((self.root / 'appcast.xml').exists())

    def test_tag_appcast_checks_history_before_calling_signer(self):
        with patch.dict(os.environ, {'AIRPLAY_REQUIRE_UPDATES':'true'}), \
                patch.object(release, 'derive_public_key', return_value=PUBLIC), \
                patch.object(release, 'previous_version_check', side_effect=ValueError('build must increase')) as history, \
                patch.object(release, 'sparkle_tool') as tool, self.assertRaisesRegex(ValueError, 'increase'):
            release.appcast(self.app, self.dmg)
        history.assert_called_once_with('1.2.3', 4)
        tool.assert_not_called()

    def test_download_checksum_rejects_untrusted_tool_before_execution(self):
        with patch.dict(os.environ, {'AIRPLAY_SPARKLE_CACHE':str(self.root / 'cache')}):
            def download(url, path):
                Path(path).write_bytes(b'untrusted archive')
            with patch.object(release.urllib.request, 'urlretrieve', side_effect=download), self.assertRaisesRegex(ValueError, 'SHA-256'):
                release.sparkle_tool()
        self.assertFalse((self.root / 'cache' / release.SPARKLE_VERSION / 'sign_update').exists())


if __name__ == '__main__':
    unittest.main()
