#!/usr/bin/env python3
"""Verify locked vendor; generate Android-only UxPlay copy and core patches."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
source = ROOT / 'vendor/UxPlay'
target = ROOT / 'build/android-uxplay-src'
lock = json.loads((ROOT / 'native/uxplay.lock.json').read_text())
for relative, expected in lock['files'].items():
    if hashlib.sha256((source / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Pinned upstream changed: {relative}')
patches = [ROOT / 'native/patches/0001-receiver-integration.patch',
           ROOT / 'android-prototype/patches/0001-core-lifetime.patch']
stamp = hashlib.sha256(b'android-core-preparation-v2'
                      + (ROOT / 'native/uxplay.lock.json').read_bytes()
                      + b''.join(p.read_bytes() for p in patches)).hexdigest()
if not (target / '.android-stamp').exists() or (target / '.android-stamp').read_text() != stamp:
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    for patch in patches:
        # git apply in a nested ignored tree can silently skip paths relative
        # to the enclosing repository. Feed only lib/ unified diffs to patch.
        text = patch.read_text()
        chunks = text.split('--- a/')
        core_patch = ''.join('--- a/' + chunk for chunk in chunks[1:] if chunk.startswith('lib/'))
        if not core_patch:
            raise SystemExit(f'No core diff found in {patch.name}')
        subprocess.run(['patch', '-p1', '--batch'], input=core_patch, text=True, cwd=target, check=True)
    (target / '.android-stamp').write_text(stamp)
if 'if (raop->httpd) httpd_stop(raop->httpd);' not in (target / 'lib/raop.c').read_text():
    raise SystemExit('Android core lifetime patch was not applied')
if 'raop_rtp->client_ntp_sync = 0;' not in (target / 'lib/raop_rtp.c').read_text():
    raise SystemExit('Existing RTP epoch recovery core patch was not applied')
print('Verified locked UxPlay and prepared Android core')
