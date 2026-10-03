#!/usr/bin/env python3
"""Inspect packaged ABI, ELF alignment, JNI symbols and license presence."""
import struct
import sys
from pathlib import Path
import zipfile

path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1] / 'build/outputs/aar/android-airplay-foundation-debug.aar')
with zipfile.ZipFile(path) as aar:
    for abi, machine in [('arm64-v8a', 183), ('x86_64', 62)]:
        blob = aar.read(f'jni/{abi}/libairplay_receiver.so')
        assert blob[:6] == b'\x7fELF\x02\x01', f'{abi}: expected ELF64 little endian'
        assert struct.unpack_from('<H', blob, 18)[0] == machine, f'{abi}: wrong machine'
        phoff = struct.unpack_from('<Q', blob, 32)[0]
        phsize, phcount = struct.unpack_from('<HH', blob, 54)
        loads = 0
        for i in range(phcount):
            kind, flags, offset, vaddr, _, filesz, memsz, alignment = struct.unpack_from(
                '<IIQQQQQQ', blob, phoff + i * phsize)
            if kind == 1:
                loads += 1
                assert alignment >= 16384 and (vaddr - offset) % 16384 == 0, f'{abi}: 16 KiB ELF alignment'
        assert loads > 0
        for method in ['open', 'closeNative', 'txtNative', 'pollNative', 'epochNative']:
            name = f'Java_io_github_boyan01_airplay_NativeReceiver_{method}'.encode()
            assert name + b'\x00' in blob, f'{abi}: JNI export missing: {method}'
    for license in ['NOTICE.md', 'OpenSSL-Apache-2.0.txt', 'UxPlay-GPL-3.0.txt',
                    'libplist-LGPL-2.1.txt', 'llhttp-MIT.txt', 'PlayFair-LICENSE.md']:
        assert len(aar.read('assets/licenses/' + license)) > 0
    assert len(aar.read('classes.jar')) > 0
print('PASS: two packaged ABIs, 16 KiB ELF load alignment, JNI names and six license/notice assets')
