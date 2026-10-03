#!/usr/bin/env python3
"""Verify vendored upstream and apply project patches to a disposable build tree."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'vendor/UxPlay'
TARGET = ROOT / 'build/uxplay-src'
lock = json.loads((ROOT / 'native/uxplay.lock.json').read_text())
for relative, expected in lock['files'].items():
    actual = hashlib.sha256((SOURCE / relative).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'Pinned upstream changed: {relative}. Keep vendor pristine; add a patch instead.')
patches = sorted((ROOT / 'native/patches').glob('*.patch'))
stamp = hashlib.sha256((ROOT / 'native/uxplay.lock.json').read_bytes() + b''.join(p.read_bytes() for p in patches)).hexdigest()
if (TARGET / '.receiver-source-stamp').exists() and (TARGET / '.receiver-source-stamp').read_text() == stamp:
    print('Pinned UxPlay + project patches already prepared.')
else:
    if TARGET.exists():
        shutil.rmtree(TARGET)
    shutil.copytree(SOURCE, TARGET)
    for patch in patches:
        subprocess.run(['patch', '-p1', '--batch', '-i', str(patch)], cwd=TARGET, check=True)
    (TARGET / '.receiver-source-stamp').write_text(stamp)
    print(f'Prepared UxPlay {lock["tag"]} ({lock["commit"]}) in build/uxplay-src.')
