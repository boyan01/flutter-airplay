#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate release metadata and publish only complete, verified asset sets."""
import argparse
import base64
import binascii
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.request
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
VERSION_RE = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
REPOSITORY = 'boyan01/flutter-airplay'
FEED_URL = f'https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
SPARKLE_VERSION = '2.10.0'
SPARKLE_ARCHIVE_SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
ET.register_namespace('sparkle', SPARKLE_NS)

# CryptoKit supplies Ed25519 on macOS; OpenSSL 3 supplies it on the Linux publisher.
SWIFT_CRYPTO = '''import Foundation
import CryptoKit
let args = CommandLine.arguments
if args[1] == "derive" {
    let seed = Data(base64Encoded: readLine()!)!
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[3])!)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    if !key.isValidSignature(Data(base64Encoded: args[4])!, for: data) { exit(1) }
}
'''


def parse_version(text):
    match = re.search(r'^version:\s*(' + VERSION_RE + r')\+([1-9][0-9]*)\s*$', text, re.MULTILINE)
    if not match:
        raise ValueError('pubspec.yaml must use major.minor.patch+positive-build.')
    # Windows VERSIONINFO stores four unsigned 16-bit integers.
    if any(int(value) > 65535 for value in (*match.groups()[1:4], match.group(5))):
        raise ValueError('Version components and build number must fit Windows VERSIONINFO (0..65535).')
    return match.group(1), int(match.group(5))


def version(root=None):
    return parse_version(((root or ROOT) / 'pubspec.yaml').read_text())[0]


def build_number(root=None):
    return parse_version(((root or ROOT) / 'pubspec.yaml').read_text())[1]


def validate_tag(tag, expected):
    if not re.fullmatch('v' + VERSION_RE, tag) or tag != 'v' + expected:
        raise ValueError('Release tag must be vMAJOR.MINOR.PATCH and match pubspec.yaml exactly.')


def changelog_entry(current, required=True):
    path = ROOT / 'CHANGELOG.md'
    if not path.exists():
        if not required:
            return ''
        raise ValueError('CHANGELOG.md is required for a release.')
    sections = re.split(r'^##[ \t]+([^\n]+)\n', path.read_text(encoding='utf-8') + '\n', flags=re.MULTILINE)
    entries = [sections[index + 1] for index in range(1, len(sections), 2)
               if sections[index].strip() == current]
    if not entries:
        if not required:
            return ''
        raise ValueError(f'CHANGELOG.md must contain ## {current}.')
    if len(entries) != 1:
        raise ValueError(f'CHANGELOG.md contains duplicate entries for {current}.')
    languages = re.split(r'^###[ \t]+([^\n]+)\n', entries[0], flags=re.MULTILINE)
    if languages[0].strip():
        raise ValueError('Changelog entries must begin with ### 中文 or ### English.')
    notes = {}
    for index in range(1, len(languages), 2):
        language = languages[index].strip()
        if language not in ('中文', 'English') or language in notes:
            raise ValueError('Changelog must contain exactly one 中文 and one English section.')
        bullets = []
        for line in languages[index + 1].splitlines():
            if not line.strip():
                continue
            if line.startswith('- ') and line[2:].strip():
                bullets.append(line[2:].strip())
            elif line.startswith(('  ', '\t')) and line.strip() and bullets:
                bullets[-1] += ' ' + line.strip()
            else:
                raise ValueError('Changelog language sections must contain nonempty - bullets with optional indented continuation lines.')
        if not bullets:
            raise ValueError(f'Changelog {language} section must contain at least one bullet.')
        notes[language] = bullets
    if set(notes) != {'中文', 'English'}:
        raise ValueError('Changelog requires both 中文 and English sections.')
    return '\n\n'.join('### ' + language + '\n' + '\n'.join('- ' + text for text in notes[language])
                       for language in ('中文', 'English'))


def update_description(current, required=False):
    notes = changelog_entry(current, required=required)
    if not notes:
        return f'Flutter AirPlay {current}. See the GitHub release for changes.'
    # Escape changelog text before embedding it as HTML in the RSS description.
    return '\n'.join('<p>' + html.escape('• ' + line[2:] if line.startswith('- ') else line[4:], quote=False) + '</p>'
                     for line in notes.splitlines() if line)


def decode_key(value, name, length):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError(f'{name} must be canonical Base64 ({length} decoded bytes).') from None
    if len(raw) != length or base64.b64encode(raw).decode() != value:
        raise ValueError(f'{name} must be canonical Base64 ({length} decoded bytes).')
    return raw


def crypto_command(args, **kwargs):
    env = dict(os.environ)
    env.pop('SPARKLE_PRIVATE_KEY', None)
    result = subprocess.run(args, capture_output=True, env=env, **kwargs)
    if result.returncode:
        # Some official tool errors echo invalid keys. Never relay their output.
        raise ValueError('Sparkle key/signature validation failed; check the signing configuration and archive.')
    return result.stdout


def derive_public_key(private_key):
    seed = decode_key(private_key, 'SPARKLE_PRIVATE_KEY', 32)
    if sys.platform == 'darwin':
        return crypto_command(['swift', '-e', SWIFT_CRYPTO, 'derive'], input=(private_key + '\n').encode()).decode().strip()
    der = bytes.fromhex('302e020100300506032b657004220420') + seed
    public_der = crypto_command(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], input=der)
    if len(public_der) != 44 or not public_der.startswith(bytes.fromhex('302a300506032b6570032100')):
        raise ValueError('OpenSSL did not return an Ed25519 public key.')
    return base64.b64encode(public_der[-32:]).decode()


def signing_config(required=False):
    private = os.environ.get('SPARKLE_PRIVATE_KEY', '')
    public = os.environ.get('SPARKLE_PUBLIC_KEY', '')
    account = os.environ.get('AIRPLAY_SPARKLE_ACCOUNT', '')
    if account:
        if sys.platform != 'darwin':
            raise ValueError('Sparkle Keychain signing requires macOS.')
        if private:
            raise ValueError('Choose either AIRPLAY_SPARKLE_ACCOUNT or SPARKLE_PRIVATE_KEY.')
        keychain_public = crypto_command([str(sparkle_tool('generate_keys')), '--account', account, '-p']).decode().strip()
        decode_key(keychain_public, 'Keychain public key', 32)
        if public and public != keychain_public:
            raise ValueError('Keychain public key does not match SPARKLE_PUBLIC_KEY.')
        return keychain_public
    if (not private or not public) and not required:
        return ''
    if not private or not public:
        raise ValueError('macOS updates require SPARKLE_PRIVATE_KEY and SPARKLE_PUBLIC_KEY; tag releases cannot omit signing configuration.')
    decode_key(public, 'SPARKLE_PUBLIC_KEY', 32)
    if derive_public_key(private) != public:
        raise ValueError('SPARKLE_PRIVATE_KEY does not match SPARKLE_PUBLIC_KEY.')
    return public


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def releases_list():
    pages = json.loads(gh('api', '--paginate', '--slurp', 'repos/{owner}/{repo}/releases'))
    return [release for page in pages for release in page]


def read_appcast(data):
    try:
        tree = ET.fromstring(data)
        items = tree.findall('./channel/item')
        if tree.tag != 'rss' or len(items) != 1:
            raise ValueError('Appcast must have exactly one update item.')
        item = items[0]
        enclosures = item.findall('enclosure')
        if len(enclosures) != 1:
            raise ValueError('Appcast must have exactly one enclosure.')
        enclosure = enclosures[0]
        short = item.findtext(f'{{{SPARKLE_NS}}}shortVersionString')
        build = item.findtext(f'{{{SPARKLE_NS}}}version')
        if not re.fullmatch(VERSION_RE, short or '') or not re.fullmatch(r'[1-9][0-9]*', build or ''):
            raise ValueError('Appcast has an invalid version/build.')
        return item, enclosure, short, int(build)
    except ET.ParseError:
        raise ValueError('Invalid appcast XML.') from None


def previous_version_check(current, build, releases=None):
    current_parts = tuple(map(int, current.split('.')))
    for previous in releases if releases is not None else releases_list():
        if previous['draft'] or previous.get('prerelease', False):
            continue
        tag = previous['tag_name']
        if not re.fullmatch('v' + VERSION_RE, tag):
            raise ValueError('Published release has an unsupported tag; cannot establish the previous update version.')
        feed = next((asset for asset in previous['assets'] if asset['name'] == 'appcast.xml'), None)
        if feed:
            data = gh('api', '-H', 'Accept: application/octet-stream', f'repos/{{owner}}/{{repo}}/releases/assets/{feed["id"]}')
            _, _, previous_short, previous_build = read_appcast(data)
            validate_tag(tag, previous_short)
        else:
            # Bootstrap from older releases that predate Sparkle, without guessing a build.
            content = json.loads(gh('api', f'repos/{{owner}}/{{repo}}/contents/pubspec.yaml?ref={tag}'))
            previous_short, previous_build = parse_version(base64.b64decode(content['content']).decode())
            validate_tag(tag, previous_short)
        if current_parts <= tuple(map(int, previous_short.split('.'))) or build <= previous_build:
            raise ValueError('Release short version and CFBundleVersion build must both increase beyond every published stable release.')


def metadata():
    current = version()
    required = os.environ.get('RELEASE_EVENT') == 'push' and os.environ.get('RELEASE_REF_TYPE') == 'tag'
    if os.environ.get('RELEASE_EVENT') not in ('workflow_dispatch', 'pull_request') or os.environ.get('RELEASE_REF_TYPE') == 'tag':
        validate_tag(os.environ.get('RELEASE_TAG', ''), current)
    if required:
        changelog_entry(current)
        signing_config(required=True)
        previous_version_check(current, build_number())
    sdk = (ROOT / '.flutter-version').read_text().strip()
    if not re.fullmatch(VERSION_RE, sdk):
        raise ValueError('Invalid pinned Flutter version.')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'version={current}\nbuild={build_number()}\nflutter_version={sdk}\n')


def sparkle_tool(name='sign_update'):
    if name not in ('sign_update', 'generate_keys'):
        raise ValueError('Unsupported Sparkle tool.')
    cache = Path(os.environ.get('AIRPLAY_SPARKLE_CACHE', Path.home() / 'Library/Caches/FlutterAirPlay/Sparkle')) / SPARKLE_VERSION
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'Sparkle-{SPARKLE_VERSION}.tar.xz'
    if not archive.exists():
        # Download into a new directory, never execute or import from the download location.
        with tempfile.TemporaryDirectory(prefix='sparkle-download-', dir=cache) as directory:
            download = Path(directory) / archive.name
            urllib.request.urlretrieve(f'https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive.name}', download)
            if hashlib.sha256(download.read_bytes()).hexdigest() != SPARKLE_ARCHIVE_SHA256:
                raise ValueError('Sparkle archive SHA-256 mismatch.')
            download.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_ARCHIVE_SHA256:
        raise ValueError('Cached Sparkle archive SHA-256 mismatch; remove the corrupt cache archive.')
    with tarfile.open(archive) as source:
        member = source.getmember(f'./bin/{name}')
        if not member.isfile():
            raise ValueError('Sparkle signing tool is not a regular file.')
        contents = source.extractfile(member).read()
    tool = cache / name
    if not tool.is_file() or tool.is_symlink() or tool.read_bytes() != contents:
        tool.unlink(missing_ok=True)
        tool.write_bytes(contents)
    tool.chmod(0o755)
    return tool


def verify_signature(archive, signature, public):
    public_bytes = decode_key(public, 'SPARKLE_PUBLIC_KEY', 32)
    signature_bytes = decode_key(signature, 'sparkle:edSignature', 64)
    if sys.platform == 'darwin':
        crypto_command(['swift', '-e', SWIFT_CRYPTO, 'verify', str(archive), public, signature])
    else:
        with tempfile.TemporaryDirectory(prefix='sparkle-verify-') as directory:
            key = Path(directory) / 'public.der'
            sig = Path(directory) / 'signature'
            key.write_bytes(bytes.fromhex('302a300506032b6570032100') + public_bytes)
            sig.write_bytes(signature_bytes)
            crypto_command(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(key),
                            '-rawin', '-in', str(archive), '-sigfile', str(sig)])


def validate_appcast(feed, dmg, current, build, public, required_notes=False):
    item, enclosure, short, actual_build = read_appcast(feed.read_bytes())
    release_url = f'https://github.com/{REPOSITORY}/releases/tag/v{current}'
    expected = {'url': f'https://github.com/{REPOSITORY}/releases/download/v{current}/{dmg.name}',
                'length': str(dmg.stat().st_size), 'type': 'application/octet-stream'}
    if (short != current or actual_build != build or
            item.findtext(f'{{{SPARKLE_NS}}}minimumSystemVersion') != '12.0' or
            item.findtext(f'{{{SPARKLE_NS}}}releaseNotesLink') != release_url or
            any(enclosure.get(key) != value for key, value in expected.items())):
        raise ValueError('Appcast metadata does not match this macOS release archive/version.')
    if required_notes and item.findtext('description') != update_description(current, required=True):
        raise ValueError('Appcast release notes do not match CHANGELOG.md.')
    verify_signature(dmg, enclosure.get(f'{{{SPARKLE_NS}}}edSignature', ''), public)


def validate_bundle_updates(app, public):
    current, build = parse_version((ROOT / 'pubspec.yaml').read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('SUPublicEDKey', '') != public or info.get('SUFeedURL') != FEED_URL or
            info.get('CFBundleShortVersionString') != current or str(info.get('CFBundleVersion')) != str(build)):
        raise ValueError('macOS bundle update key/feed/version does not match the signing configuration.')


def appcast(app, dmg):
    current, build = parse_version((ROOT / 'pubspec.yaml').read_text())
    description = update_description(current, required=os.environ.get('AIRPLAY_REQUIRE_UPDATES') == 'true')
    public = signing_config(required=True)
    validate_bundle_updates(app, public)
    if dmg.name != f'Flutter-AirPlay-{current}-macos-arm64.dmg' or not dmg.is_file() or dmg.is_symlink() or not dmg.stat().st_size:
        raise ValueError('Unexpected macOS update archive.')
    if os.environ.get('AIRPLAY_REQUIRE_UPDATES') == 'true':
        previous_version_check(current, build)
    tool = sparkle_tool()
    account = os.environ.get('AIRPLAY_SPARKLE_ACCOUNT', '')
    key_args = ['--account', account] if account else ['--ed-key-file', '-']
    private_input = None if account else (os.environ['SPARKLE_PRIVATE_KEY'] + '\n').encode()
    signature = crypto_command([str(tool), *key_args, '-p', str(dmg)], input=private_input).decode().strip()
    decode_key(signature, 'sparkle:edSignature', 64)
    crypto_command([str(tool), *key_args, '--verify', str(dmg), signature], input=private_input)
    verify_signature(dmg, signature, public)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Flutter AirPlay updates'
    ET.SubElement(channel, 'link').text = FEED_URL
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Flutter AirPlay {current}'
    ET.SubElement(item, 'description').text = description
    for name, text in (('version', str(build)), ('shortVersionString', current), ('minimumSystemVersion', '12.0'),
                       ('releaseNotesLink', f'https://github.com/{REPOSITORY}/releases/tag/v{current}')):
        ET.SubElement(item, f'{{{SPARKLE_NS}}}{name}').text = text
    ET.SubElement(item, 'enclosure', {'url': f'https://github.com/{REPOSITORY}/releases/download/v{current}/{dmg.name}',
                                    'length': str(dmg.stat().st_size), 'type': 'application/octet-stream',
                                    f'{{{SPARKLE_NS}}}edSignature': signature})
    feed = dmg.parent / 'appcast.xml'
    ET.indent(rss)
    feed.write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n')
    validate_appcast(feed, dmg, current, build, public)


ANDROID_NS = 'https://github.com/boyan01/flutter-airplay/updates'
ET.register_namespace('airplay', ANDROID_NS)


def add_android_appcast(feed, apk, current, version_code):
    if not re.fullmatch(r'[1-9][0-9]*', version_code or ''):
        raise ValueError('Android release job must report the actual APK versionCode.')
    item, _, short, _ = read_appcast(feed.read_bytes())
    if short != current:
        raise ValueError('Unexpected Android appcast version.')
    tree = ET.parse(feed)
    item = tree.find('./channel/item')
    attributes = {
        'version': current, 'versionCode': version_code,
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{current}/{apk.name}',
        'length': str(apk.stat().st_size), 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
    }
    existing = item.findall(f'{{{ANDROID_NS}}}android')
    if existing:
        if len(existing) != 1 or existing[0].attrib != attributes:
            raise ValueError('Existing Android appcast metadata does not match this APK.')
        return
    ET.SubElement(item, f'{{{ANDROID_NS}}}android', attributes)
    ET.indent(tree)
    tree.write(feed, encoding='utf-8', xml_declaration=True)


def asset_names(current, signed):
    prefix = f'Flutter-AirPlay-{current}'
    names = [f'{prefix}-linux-x64.deb', f'{prefix}-linux-x64-bundle.tar.gz',
             f'{prefix}-windows-x64-setup.exe', f'{prefix}-macos-arm64.dmg', 'appcast.xml']
    if signed:
        names.append(f'{prefix}-android-arm64.apk')
    return names


def collect(directory, current, signed):
    expected = asset_names(current, signed)
    actual = {path.name for path in directory.iterdir()}
    if actual != set(expected):
        raise ValueError(f'Unexpected release asset set; expected {expected}, got {sorted(actual)}')
    paths = [directory / name for name in expected]
    for path in paths:
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise ValueError(f'Missing, empty or invalid release asset: {path.name}')
    sums = directory / 'SHA256SUMS'
    sums.write_text(''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in paths))
    return paths + [sums]


def verify_remote_tag(tag, expected_sha):
    if not re.fullmatch(r'[0-9a-f]{40}', expected_sha):
        raise ValueError('Invalid release commit SHA.')
    # Read the remote ref, peeling annotated tags without executing repository code.
    obj = json.loads(gh('api', f'repos/{{owner}}/{{repo}}/git/ref/tags/{tag}'))['object']
    for _ in range(10):
        if obj['type'] == 'commit':
            if obj['sha'] != expected_sha:
                raise ValueError('Release tag moved since this build; refusing to publish mismatched binaries.')
            return
        if obj['type'] != 'tag' or not re.fullmatch(r'[0-9a-f]{40}', obj['sha']):
            break
        obj = json.loads(gh('api', f'repos/{{owner}}/{{repo}}/git/tags/{obj["sha"]}'))['object']
    raise ValueError('Release tag does not resolve to the expected commit.')


def publish():
    current = version()
    tag = os.environ['RELEASE_TAG']
    validate_tag(tag, current)
    changes = changelog_entry(current)
    verify_remote_tag(tag, os.environ['RELEASE_SHA'])
    signed_text = os.environ.get('ANDROID_SIGNED')
    if signed_text not in ('true', 'false'):
        raise ValueError('Android job must explicitly report signed=true or signed=false.')
    public = os.environ.get('SPARKLE_PUBLIC_KEY', '')
    decode_key(public, 'SPARKLE_PUBLIC_KEY', 32)
    signed = signed_text == 'true'
    directory = ROOT / 'build/release-assets'
    if signed:
        add_android_appcast(directory / 'appcast.xml',
                            directory / f'Flutter-AirPlay-{current}-android-arm64.apk',
                            current, os.environ.get('ANDROID_VERSION_CODE', ''))
    files = collect(directory, current, signed)
    validate_appcast(directory / 'appcast.xml', directory / f'Flutter-AirPlay-{current}-macos-arm64.dmg', current, build_number(), public, required_notes=True)
    # Listing avoids treating an authorization/network failure as a missing release.
    releases = releases_list()
    existing = next((r for r in releases if r['tag_name'] == tag), None)
    if existing and not existing['draft']:
        raise ValueError('Refusing to replace an already published release. Use a new version/tag.')
    previous_version_check(current, build_number(), releases)
    if existing and (existing['target_commitish'] != os.environ['RELEASE_SHA'] or
                     any(a['name'] not in {p.name for p in files} for a in existing['assets'])):
        raise ValueError('Existing draft does not match this release run; inspect it manually.')
    notes = ('Linux x64: Ubuntu 24.04 or compatible system with the documented runtime dependencies.\n'
             'Windows x64: Setup is not Authenticode-signed.\n'
             'macOS arm64 (Apple Silicon, macOS 12+): App in DMG is ad-hoc signed, not Developer ID signed or notarized.\n'
             'Drag the app to Applications. macOS may block downloaded apps from unidentified developers.\n'
             'macOS updates: Sparkle appcast.xml and Ed25519-signed DMG included.\n')
    notes += ('Android arm64: signed release APK included.\n' if signed else
              'Android APK omitted: release signing secrets have not been configured.\n')
    notes += '\nChecksums: SHA256SUMS. Source and license notices are included in the application packages.\n'
    notes = changes + '\n\n### Downloads and installation\n\n' + notes
    with tempfile.TemporaryDirectory(prefix='airplay-release-notes-') as temporary:
        notes_file = Path(temporary) / 'notes.txt'
        notes_file.write_text(notes)
        if not existing:
            gh('release', 'create', tag, '--verify-tag', '--target', os.environ['RELEASE_SHA'],
               '--draft', '--title', f'Flutter AirPlay {current}', '--notes-file', str(notes_file))
        else:
            gh('release', 'edit', tag, '--notes-file', str(notes_file))
    # Keep the release a draft if any upload fails. Retrying may replace only draft assets.
    gh('release', 'upload', tag, *map(str, files), '--clobber')
    uploaded = json.loads(gh('release', 'view', tag, '--json', 'assets'))['assets']
    if {a['name']: a['size'] for a in uploaded} != {p.name: p.stat().st_size for p in files}:
        raise ValueError('Uploaded release assets are incomplete or have unexpected sizes; draft retained.')
    verify_remote_tag(tag, os.environ['RELEASE_SHA'])
    # Recheck global history after uploads, including concurrent releases on other tags.
    previous_version_check(current, build_number())
    gh('release', 'edit', tag, '--draft=false', '--latest', '--tag', tag, '--verify-tag')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'Published {tag}: {len(files) - 2} application assets, appcast.xml and SHA256SUMS.\n{notes}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('metadata', 'publish', 'updates-config', 'updates-bundle', 'appcast'))
    parser.add_argument('--required', action='store_true')
    parser.add_argument('--app', type=Path)
    parser.add_argument('--dmg', type=Path)
    try:
        args = parser.parse_args()
        if args.command == 'updates-config':
            print(signing_config(args.required))
        elif args.command == 'updates-bundle':
            if not args.app:
                raise ValueError('updates-bundle requires --app.')
            validate_bundle_updates(args.app, signing_config(args.required))
        elif args.command == 'appcast':
            if not args.app or not args.dmg:
                raise ValueError('appcast requires --app and --dmg.')
            appcast(args.app, args.dmg)
        else:
            {'metadata': metadata, 'publish': publish}[args.command]()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        parser.exit(1, f'Release failed: {error}\n')
