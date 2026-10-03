#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fetch pinned native dependencies; never modify a dirty dependency tree."""
import json
from pathlib import Path
import subprocess
app = Path(__file__).resolve().parents[1]
cache = app / '.cache/deps'
cache.mkdir(parents=True, exist_ok=True)
lock = json.loads((app / 'dependencies.lock.json').read_text())
for name in ('openssl', 'libplist', 'oboe'):
    entry = lock[name]
    target = cache / name
    if not target.exists():
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', entry['tag'], entry['repository'], str(target)], check=True)
    commit = subprocess.check_output(['git', '-C', str(target), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(target), 'status', '--porcelain'], text=True).strip()
    if commit != entry['commit'] or dirty:
        raise SystemExit(f'{name}: unexpected commit or uncommitted changes')
    print(f'{name}: pinned source ready')
