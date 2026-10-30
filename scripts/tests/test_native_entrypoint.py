"""Exercise native suite dispatch without invoking platform compilers or GUIs."""
import pathlib
import subprocess
import unittest


class MacOSSuiteDispatchTest(unittest.TestCase):
    def run_suite(self, *arguments):
        source = (pathlib.Path(__file__).resolve().parents[1] / 'test_native.sh').read_text()
        # Execute the production dispatcher, replacing only its platform workers.
        dispatcher = source.split('macos_tests() {', 1)[1].split('\nandroid_tests()', 1)[0]
        workers = '\n'.join(
            f'macos_{name}() {{ echo {name}; }}'
            for name in ('player', 'host', 'texture', 'rtp')
        )
        script = 'set -e\nfail() { exit 1; }\n' + workers + '\nmacos_tests() {' + dispatcher
        return subprocess.run(
            ['bash', '-c', script + '\nmacos_tests "$@"', 'native-suite', *arguments],
            check=False, capture_output=True, text=True,
        )

    def test_all_runs_each_headless_fixture_once(self):
        result = self.run_suite('all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['player', 'host', 'texture', 'rtp'])

    def test_default_stays_headless_and_window_is_removed(self):
        result = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['player'])
        self.assertNotEqual(self.run_suite('window').returncode, 0)

    def test_all_rejects_player_only_filter_arguments(self):
        result = self.run_suite('all', '-R', 'playback')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


class NativeAllScopeTest(unittest.TestCase):
    def run_suite(self, *arguments):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for build in ('windows/x64/native', 'windows/x64'):
                (root / 'build' / build).mkdir(parents=True, exist_ok=True)
                (root / 'build' / build / 'CTestTestfile.cmake').touch()
            (root / 'build/windows/x64/native/CMakeCache.txt').touch()
            # The lychee_player plugin's DLL from the Flutter build.
            (root / 'build/windows/x64/runner/Debug').mkdir(parents=True)
            (root / 'build/windows/x64/runner/Debug/lychee_player.dll').touch()
            source = (pathlib.Path(__file__).resolve().parents[1] / 'test_native.sh').read_text()
            definitions, dispatch = source.split('\nif [[ $# -eq 0 ]]; then\n    case "$(uname -s)"', 1)
            script = definitions + '\n' + '''
project_root="$1"
shift
linux_tests() { echo native; }
cmake() { :; }
ctest() { case "$2" in */windows/x64/native) echo native ;; */windows/x64) echo texture ;; esac; }
''' + '\nif [[ $# -eq 0 ]]; then\n    case "$(uname -s)"' + dispatch
            return subprocess.run(['bash', '-c', script, 'native-all', str(root), *arguments],
                                  capture_output=True, text=True, check=False)

    def test_unfiltered_all_keeps_native_suites_without_extra_window_tests(self):
        for platform, expected in (('linux', ['native']),
                                   ('windows', ['native', 'texture'])):
            with self.subTest(platform=platform):
                result = self.run_suite(platform, 'all')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_scoped_all_does_not_run_unrelated_suites(self):
        for arguments in (('linux', 'all', '--filter', 'linux_playback'),
                          ('windows', 'all', '-R', 'windows_pixels')):
            with self.subTest(arguments=arguments):
                result = self.run_suite(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ['native'])
