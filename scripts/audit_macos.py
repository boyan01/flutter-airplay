#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reject missing, external or Intel-only runtime binaries in a packaged app."""
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
frameworks = app / 'Contents/Frameworks'
count = 0
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    description = subprocess.check_output(['/usr/bin/file', '-b', str(path)], text=True)
    if 'Mach-O' not in description:
        continue
    count += 1
    arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True)
    if 'arm64' not in arch.split():
        raise SystemExit(f'No arm64 slice: {path.relative_to(app)}')
    links = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    for line in links.splitlines():
        if ' (compatibility version ' not in line:
            continue
        dependency = line.strip().split(' (compatibility version ', 1)[0]
        if dependency.startswith(('/System/Library/', '/usr/lib/')):
            continue
        candidates = []
        if dependency.startswith('@rpath/'):
            candidates = [frameworks / dependency[7:], path.parent / dependency[7:]]
        elif dependency.startswith('@loader_path/'):
            candidates = [path.parent / dependency[13:]]
        elif dependency.startswith('@executable_path/'):
            candidates = [app / 'Contents/MacOS' / dependency[17:]]
        if not any(candidate.exists() for candidate in candidates):
            raise SystemExit(f'Unbundled dependency in {path.relative_to(app)}: {dependency}')
if count == 0 or not (frameworks / 'libairplay_player.dylib').is_file():
    raise SystemExit('Shared player or application binaries missing')
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'PASS: {count} Mach-O binaries have arm64 and only bundled/system runtime dependencies; signature verified')
