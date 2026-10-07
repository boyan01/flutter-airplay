"""Probe the production CI libclang selection and fallback without apt/network."""
import contextlib
import ctypes
import io
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock


WORKFLOW = pathlib.Path(__file__).resolve().parents[2] / '.github/workflows/ci.yml'


def ffi_step():
    source = WORKFLOW.read_text().split('      - name: Check generated FFI bindings\n', 1)[1]
    return textwrap.dedent(source.split('        run: |\n', 1)[1].split('\n      - ', 1)[0])


class LibclangProbeTest(unittest.TestCase):
    def probe(self, paths, libraries):
        source = ffi_step().split("<<'CLANG_PROBE'\n", 1)[1].split('\nCLANG_PROBE', 1)[0]
        output = io.StringIO()
        with mock.patch('glob.glob', side_effect=[paths, []]), \
             mock.patch('ctypes.CDLL', side_effect=lambda path: libraries[path]), \
             contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as result:
                exec(compile(source, '<CI libclang probe>', 'exec'), {})
        return result.exception.code, output.getvalue().strip()

    def test_runtime_soname_is_loaded_and_c_api_is_called(self):
        library = mock.Mock()
        library.clang_createIndex.return_value = 123
        path = '/usr/lib/llvm-18/lib/libclang.so.1'
        self.assertEqual(self.probe([path], {path: library}), (0, path))
        library.clang_createIndex.assert_called_once_with(0, 0)
        library.clang_disposeIndex.assert_called_once_with(123)
        self.assertEqual(library.clang_createIndex.restype, ctypes.c_void_p)

    def test_missing_api_and_null_index_do_not_claim_a_usable_library(self):
        missing = object()
        null = mock.Mock()
        null.clang_createIndex.return_value = None
        paths = ['/usr/lib/llvm-18/lib/libclang.so.1', '/usr/lib/llvm-17/lib/libclang.so.1']
        self.assertEqual(self.probe(paths, dict(zip(paths, [missing, null]))), (1, ''))
        null.clang_disposeIndex.assert_not_called()

    def test_missing_library_fails_and_versions_are_ordered_numerically(self):
        self.assertEqual(self.probe([], {}), (1, ''))
        library = mock.Mock()
        library.clang_createIndex.return_value = 123
        paths = ['/usr/lib/llvm-9/lib/libclang.so', '/usr/lib/llvm-18/lib/libclang.so.1']
        self.assertEqual(self.probe(paths, {path: library for path in paths}), (0, paths[1]))


class LibclangFallbackTest(unittest.TestCase):
    def run_step(self, mode, apt_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'tool').mkdir()
            (root / 'bin').mkdir()
            original = 'name: Bindings\nheaders:\n  entry-points: [../header.h]\n'
            (root / 'tool/ffigen_receiver.yaml').write_text(original)
            commands = {
                'python3': '''#!/usr/bin/env bash
count=0
[[ ! -f "$ROOT/count" ]] || count=$(cat "$ROOT/count")
echo $((count + 1)) > "$ROOT/count"
if [[ "$MODE" == ready || ( "$MODE" == fallback && $count -gt 0 ) ]]; then
  echo /usr/lib/llvm-18/lib/libclang.so.1
else
  exit 1
fi
''',
                'sudo': '#!/usr/bin/env bash\nprintf "%s " "$@" >> "$ROOT/apt"\nprintf "\\n" >> "$ROOT/apt"\nexit "$APT_EXIT"\n',
                'dart': '#!/usr/bin/env bash\ncat "$4" > "$ROOT/generated-config"\n',
                'git': '#!/usr/bin/env bash\nexit 0\n',
            }
            for name, content in commands.items():
                command = root / 'bin' / name
                command.write_text(content)
                command.chmod(0o755)
            env = dict(os.environ, ROOT=str(root), MODE=mode, APT_EXIT=str(apt_exit),
                       PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', ffi_step()],
                                    cwd=root, env=env, capture_output=True, text=True)
            files = {p.name: p.read_text() for p in root.iterdir() if p.is_file()}
            self.assertEqual((root / 'tool/ffigen_receiver.yaml').read_text(), original)
            self.assertEqual(list((root / 'tool').glob('ffigen_ci_*')), [])
            return result, files

    def test_available_library_avoids_apt_and_preserves_relative_config(self):
        result, files = self.run_step('ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('apt', files)
        self.assertIn('../header.h', files['generated-config'])
        self.assertIn('llvm-path:\n  - "/usr/lib/llvm-18/lib/libclang.so.1"', files['generated-config'])

    def test_missing_library_uses_bounded_fallback_and_reprobes(self):
        result, files = self.run_step('fallback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files['count'].strip(), '2')
        self.assertIn('timeout 120s apt-get', files['apt'])
        self.assertIn('timeout 180s apt-get', files['apt'])
        self.assertIn('--no-install-recommends libclang-dev', files['apt'])

    def test_failed_install_or_failed_reprobe_stays_red(self):
        for mode, apt_exit in [('missing', 0), ('fallback', 7)]:
            result, files = self.run_step(mode, apt_exit)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('generated-config', files)
