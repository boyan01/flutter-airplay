#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Sign and audit the self-contained Apple Silicon Release application."""
import argparse
import pathlib
import plistlib
import subprocess
import sys
import re
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True)


def binaries(app):
    return [path for path in sorted(app.rglob('*'))
            if path.is_file() and not path.is_symlink()
            and 'Mach-O' in output('/usr/bin/file', '-b', path)]


def signature_options(path):
    # Preserve helpers' sandbox exceptions and hardened runtime when re-signing.
    details = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(path)],
                             text=True, capture_output=True)
    if details.returncode:
        return {}, False
    entitlements = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', ':-', str(path)],
                                  capture_output=True, check=True).stdout
    return (plistlib.loads(entitlements) if entitlements else {},
            bool(re.search(r'flags=.*\bruntime\b', details.stderr)))


def sign(app):
    # Snapshot signatures before nested executables invalidate enclosing seals.
    paths = binaries(app)
    bundles = [path for path in app.rglob('*') if path.is_dir() and not path.is_symlink()
               and path.suffix in ('.framework', '.app', '.xpc', '.appex', '.bundle')]
    options = {path: signature_options(path) for path in [*paths, *bundles, app]}

    def sign_path(path, root=False):
        entitlements, runtime = options[path]
        command = ['/usr/bin/codesign', '--force', '--sign', '-']
        if runtime:
            command += ['--options', 'runtime']
        with tempfile.TemporaryDirectory(prefix='airplay-sign-') as temporary:
            if root:
                command += ['--entitlements', str(ROOT / 'macos/Runner/Release.entitlements')]
            elif entitlements:
                entitlement_file = pathlib.Path(temporary) / 'entitlements.plist'
                entitlement_file.write_bytes(plistlib.dumps(entitlements))
                command += ['--entitlements', str(entitlement_file)]
            subprocess.run([*command, str(path)], check=True)

    # No --deep signing: sign each leaf, then enclosing bundles, then the app.
    for path in paths:
        # Flutter's prebuilt engine may retain its build-host /usr/local/lib
        # runpath. Remove external search roots in the staging copy only;
        # the subsequent dependency audit still rejects unbundled libraries.
        for value in dict.fromkeys(raw_rpaths(path)):
            resolved = loader_path(value, path, app)
            if resolved is None or not (resolved.resolve().is_relative_to(app.resolve()) or system_path(resolved)):
                subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', value, str(path)], check=True)
        sign_path(path)
    for path in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
        sign_path(path)
    sign_path(app, root=True)
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    main_executable = app / 'Contents/MacOS' / app_info['CFBundleExecutable']
    for path in [*paths, *bundles]:
        if path == main_executable:
            continue
        if signature_options(path) != options[path]:
            raise ValueError(f'Nested signature entitlements or runtime changed: {path.relative_to(app)}')


def executable_directory(binary, app):
    # Sparkle's Updater.app and XPC executables resolve their own executable path.
    for parent in binary.parents:
        if parent == app or parent.suffix in ('.app', '.xpc', '.appex'):
            info_path = parent / 'Contents/Info.plist'
            if info_path.is_file():
                info = plistlib.loads(info_path.read_bytes())
                if info.get('CFBundleExecutable'):
                    return parent / 'Contents/MacOS'
        if parent == app:
            break
    return app / 'Contents/MacOS'


def loader_path(value, binary, app):
    for prefix, base in (('@loader_path/', binary.parent),
                         ('@executable_path/', executable_directory(binary, app))):
        if value == prefix.rstrip('/'):
            return base
        if value.startswith(prefix):
            return base / value[len(prefix):]
    return pathlib.Path(value) if value.startswith('/') else None


def system_path(path):
    # Modern macOS system dylibs may live only in the dyld shared cache.
    resolved = path.resolve()
    return any(resolved.is_relative_to(root) for root in (pathlib.Path('/usr/lib'), pathlib.Path('/System/Library')))


def raw_rpaths(binary):
    lines = output('/usr/bin/otool', '-l', binary).splitlines()
    return [lines[index + 2].strip().removeprefix('path ').rsplit(' (offset ', 1)[0]
            for index, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']


def rpaths(binary, app):
    result = []
    for value in raw_rpaths(binary):
        resolved = loader_path(value, binary, app)
        if resolved is None or not (resolved.resolve().is_relative_to(app.resolve()) or system_path(resolved)):
            raise ValueError(f'External or unsupported runtime search path in {binary.relative_to(app)}: {value}')
        result.append(resolved)
    return result


def bundled(path, app):
    return path.exists() and path.resolve().is_relative_to(app.resolve())


def audit(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                        (ROOT / 'pubspec.yaml').read_text(), re.MULTILINE)
    if not version or (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != version.groups():
        raise ValueError('Application version/build does not match pubspec.yaml')
    if info.get('CFBundleIdentifier') != 'tech.soit.flutterairplay':
        raise ValueError('Unexpected application bundle identifier')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file():
        raise ValueError('Application executable missing')
    if not info.get('NSLocalNetworkUsageDescription') or not {'_airplay._tcp', '_raop._tcp'}.issubset(info.get('NSBonjourServices', [])):
        raise ValueError('Local network/Bonjour declarations missing')
    assets = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets'
    for source in (ROOT / 'assets/licenses').iterdir():
        if source.is_file() and (assets / 'assets/licenses' / source.name).read_bytes() != source.read_bytes():
            raise ValueError(f'Bundled license differs: {source.name}')
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        if (app / 'Contents/Resources/licenses' / name).read_bytes() != (ROOT / name).read_bytes():
            raise ValueError(f'Missing or changed distribution notice: {name}')
    if not (assets / 'NOTICES.Z').is_file():
        raise ValueError('Flutter package notices missing')
    paths = binaries(app)
    required = [executable, *(app / 'Contents/Frameworks' / name for name in
                             ('libairplay_player.dylib', 'App.framework/App', 'FlutterMacOS.framework/FlutterMacOS',
                              'Sparkle.framework/Versions/B/Sparkle',
                              'Sparkle.framework/Versions/B/Autoupdate',
                              'Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
                              'Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
                              'Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer'))]
    for path in required:
        if not bundled(path, app) or path.resolve() not in paths:
            raise ValueError(f'Required application binary missing: {path.relative_to(app)}')
    for path in paths:
        if 'arm64' not in output('/usr/bin/lipo', '-archs', path).split():
            raise ValueError(f'No arm64 slice: {path.relative_to(app)}')
        host_directory = executable_directory(path, app)
        host_info = plistlib.loads((host_directory.parent / 'Info.plist').read_bytes())
        host_executable = host_directory / host_info['CFBundleExecutable']
        search = rpaths(path, app) + rpaths(host_executable, app)
        identity = output('/usr/bin/otool', '-D', path).splitlines()[1:]
        for line in output('/usr/bin/otool', '-L', path).splitlines():
            if ' (compatibility version ' not in line:
                continue
            dependency = line.strip().split(' (compatibility version ', 1)[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            # otool -L includes a dylib's own install name, not a dependency.
            if dependency in identity:
                continue
            candidates = ([base / dependency[7:] for base in search] if dependency.startswith('@rpath/')
                          else [loader_path(dependency, path, app)])
            if not any(candidate is not None and (bundled(candidate, app) or system_path(candidate)) for candidate in candidates):
                raise ValueError(f'Unbundled dependency in {path.relative_to(app)}: {dependency}')
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True)
    entitlements = plistlib.loads(subprocess.check_output(
        ['/usr/bin/codesign', '--display', '--entitlements', ':-', str(app)]))
    expected = plistlib.loads((ROOT / 'macos/Runner/Release.entitlements').read_bytes())
    if entitlements != expected:
        raise ValueError('Release entitlements changed during packaging')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'PASS: {len(paths)} arm64 Mach-O binaries, bundled/system dependencies, licenses, Bonjour and signatures')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sign', action='store_true')
    parser.add_argument('--smoke', action='store_true', help='Load packaged native runtime without starting reception')
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    try:
        app = args.app.resolve()
        if args.sign:
            sign(app)
        audit(app)
        if args.smoke:
            subprocess.run([sys.executable, '-c',
                            'import ctypes, os, sys; '
                            'player = ctypes.CDLL(sys.argv[1], mode=os.RTLD_NOW); '
                            'player.airplay_receiver_abi_version.argtypes = []; '
                            'player.airplay_receiver_abi_version.restype = ctypes.c_uint32; '
                            'assert player.airplay_receiver_abi_version() == 3, "Unexpected receiver ABI"',
                            str(app / 'Contents/Frameworks/libairplay_player.dylib')],
                           check=True, timeout=30)
            print('PASS: packaged native runtime loaded and ABI matched; no receiver started')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'macOS package audit failed: {error}\n')
