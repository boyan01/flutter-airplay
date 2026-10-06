#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Move the real Flutter caption using X11 input in an isolated desktop."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True).strip()


def geometry(window):
    values = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', window).splitlines())
    return {key: int(values[key]) for key in ('X', 'Y', 'WIDTH', 'HEIGHT')}


def main():
    app = Path(sys.argv[1]).resolve()
    if not app.is_file():
        raise RuntimeError('Build the Linux Flutter application before running this test')
    with tempfile.TemporaryDirectory(prefix='airplay-window-drag-') as temporary:
        base = Path(temporary)
        settings = base / 'config' / 'flutter-airplay'
        settings.mkdir(parents=True)
        (settings / 'receiver.ini').write_text('[Receiver]\nname=Synthetic window drag\nautoStart=false\n')
        environment = dict(os.environ, XDG_CONFIG_HOME=str(base / 'config'),
                           XDG_DATA_HOME=str(base / 'data'), GIO_USE_VFS='local',
                           GTK_USE_PORTAL='0', NO_AT_BRIDGE='1')
        with (base / 'desktop.log').open('w+') as log:
            wm = subprocess.Popen(['openbox', '--sm-disable'], env=environment, stdout=log, stderr=log)
            process = subprocess.Popen([str(app)], env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Application exited before displaying its window')
                    found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(process.pid),
                                            '--name', '^Flutter AirPlay$'], capture_output=True, text=True)
                    if found.returncode == 0:
                        window = found.stdout.splitlines()[0]
                        break
                    time.sleep(.1)
                else:
                    raise RuntimeError('Application did not show its first frame')
                time.sleep(.5)
                before = geometry(window)
                xdo('mousemove', '--window', window, 120, 18)
                xdo('mousedown', 1)
                try:
                    time.sleep(.1)
                    for step in range(1, 5):
                        xdo('mousemove', before['X'] + 120 + 30 * step, before['Y'] + 18 + 15 * step)
                        time.sleep(.15)
                finally:
                    xdo('mouseup', 1)
                time.sleep(.3)
                after = geometry(window)
                if after['X'] - before['X'] < 60 or after['Y'] - before['Y'] < 30:
                    raise AssertionError(f'Caption did not move the window: {before} -> {after}')
                print(f'Window moved by ({after["X"]-before["X"]}, {after["Y"]-before["Y"]})', flush=True)
                if (after['WIDTH'], after['HEIGHT']) != (before['WIDTH'], before['HEIGHT']):
                    raise AssertionError('Dragging changed the window size')
                xdo('mousemove', '--window', window, after['WIDTH'] - 23, 18)
                xdo('click', 1)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    visible = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(process.pid),
                                              '--name', '^Flutter AirPlay$'], capture_output=True, text=True)
                    if visible.returncode != 0:
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError('Caption close did not hide the window')
                if process.poll() is not None:
                    raise AssertionError('Close-to-tray stopped the background receiver')
                print('PASS: caption drag moved the GTK window; size preserved; close hid the window')
            except Exception:
                log.flush()
                log.seek(0)
                sys.stderr.write(log.read())
                raise
            finally:
                for child in (process, wm):
                    if child.poll() is None:
                        child.terminate()
                        child.wait(timeout=10)


if __name__ == '__main__':
    main()
