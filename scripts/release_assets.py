#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate release metadata and publish only complete, verified asset sets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VERSION_RE = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'


def version(root=ROOT):
    match = re.search(r'^version:\s*(' + VERSION_RE + r')\+([1-9][0-9]*)\s*$',
                      (root / 'pubspec.yaml').read_text(), re.MULTILINE)
    if not match:
        raise ValueError('pubspec.yaml must use major.minor.patch+positive-build.')
    # Windows VERSIONINFO stores four unsigned 16-bit integers.
    if any(int(value) > 65535 for value in (*match.groups()[1:4], match.group(5))):
        raise ValueError('Version components and build number must fit Windows VERSIONINFO (0..65535).')
    return match.group(1)


def validate_tag(tag, expected):
    if not re.fullmatch('v' + VERSION_RE, tag) or tag != 'v' + expected:
        raise ValueError('Release tag must be vMAJOR.MINOR.PATCH and match pubspec.yaml exactly.')


def metadata():
    current = version()
    if os.environ.get('RELEASE_EVENT') not in ('workflow_dispatch', 'pull_request') or os.environ.get('RELEASE_REF_TYPE') == 'tag':
        validate_tag(os.environ.get('RELEASE_TAG', ''), current)
    sdk = (ROOT / '.flutter-version').read_text().strip()
    if not re.fullmatch(VERSION_RE, sdk):
        raise ValueError('Invalid pinned Flutter version.')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'version={current}\nflutter_version={sdk}\n')


def asset_names(current, signed):
    prefix = f'Flutter-AirPlay-{current}'
    names = [f'{prefix}-linux-x64.deb', f'{prefix}-linux-x64-bundle.tar.gz',
             f'{prefix}-windows-x64-setup.exe', f'{prefix}-macos-arm64.dmg']
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


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


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
    verify_remote_tag(tag, os.environ['RELEASE_SHA'])
    signed_text = os.environ.get('ANDROID_SIGNED')
    if signed_text not in ('true', 'false'):
        raise ValueError('Android job must explicitly report signed=true or signed=false.')
    signed = signed_text == 'true'
    files = collect(ROOT / 'build/release-assets', current, signed)
    # Listing avoids treating an authorization/network failure as a missing release.
    releases = json.loads(gh('api', '--paginate', '--slurp', 'repos/{owner}/{repo}/releases'))
    existing = next((r for page in releases for r in page if r['tag_name'] == tag), None)
    if existing and not existing['draft']:
        raise ValueError('Refusing to replace an already published release. Use a new version/tag.')
    if existing and (existing['target_commitish'] != os.environ['RELEASE_SHA'] or
                     any(a['name'] not in {p.name for p in files} for a in existing['assets'])):
        raise ValueError('Existing draft does not match this release run; inspect it manually.')
    notes = ('Linux x64: Ubuntu 24.04 or compatible system with the documented runtime dependencies.\n'
             'Windows x64: Setup is not Authenticode-signed.\n'
             'macOS arm64 (Apple Silicon, macOS 12+): App in DMG is ad-hoc signed, not Developer ID signed or notarized.\n'
             'Drag the app to Applications. macOS may block downloaded apps from unidentified developers.\n')
    notes += ('Android arm64: signed release APK included.\n' if signed else
              'Android APK omitted: release signing secrets have not been configured.\n')
    notes += '\nChecksums: SHA256SUMS. Source and license notices are included in the application packages.\n'
    if not existing:
        gh('release', 'create', tag, '--verify-tag', '--target', os.environ['RELEASE_SHA'],
           '--draft', '--title', f'Flutter AirPlay {current}', '--notes', notes)
    else:
        gh('release', 'edit', tag, '--notes', notes)
    # Keep the release a draft if any upload fails. Retrying may replace only draft assets.
    gh('release', 'upload', tag, *map(str, files), '--clobber')
    uploaded = json.loads(gh('release', 'view', tag, '--json', 'assets'))['assets']
    if {a['name']: a['size'] for a in uploaded} != {p.name: p.stat().st_size for p in files}:
        raise ValueError('Uploaded release assets are incomplete or have unexpected sizes; draft retained.')
    verify_remote_tag(tag, os.environ['RELEASE_SHA'])
    gh('release', 'edit', tag, '--draft=false', '--tag', tag, '--verify-tag')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'Published {tag}: {len(files) - 1} application assets and SHA256SUMS.\n{notes}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('metadata', 'publish'))
    try:
        {'metadata': metadata, 'publish': publish}[parser.parse_args().command]()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release failed: {error}\n')
