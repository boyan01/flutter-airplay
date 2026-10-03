#!/usr/bin/env python3
"""Fetch exact public source dependencies; never install SDKs or accept licenses."""
import json
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
for name, spec in json.loads((ROOT / 'dependencies.lock.json').read_text()).items():
    target = ROOT / '.cache/deps' / name
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', spec['tag'],
                        spec['repository'], str(target)], check=True)
    actual = subprocess.check_output(['git', '-C', str(target), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != spec['commit']:
        raise SystemExit(f'Unexpected {name} commit; refusing to build')
    if subprocess.check_output(['git', '-C', str(target), 'status', '--porcelain'], text=True):
        raise SystemExit(f'{name} source has local changes; refusing to build')
print('Dependency source commits verified')
