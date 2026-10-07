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
            for name in ('player', 'host', 'texture', 'rtp', 'window')
        )
        script = 'set -e\nfail() { exit 1; }\n' + workers + '\nmacos_tests() {' + dispatcher
        return subprocess.run(
            ['bash', '-c', script + '\nmacos_tests "$@"', 'native-suite', *arguments],
            check=False, capture_output=True, text=True,
        )

    def test_all_runs_each_fixture_once_including_window(self):
        result = self.run_suite('all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['player', 'host', 'texture', 'rtp', 'window'])

    def test_default_stays_headless_and_window_remains_selectable(self):
        for arguments, expected in (((), 'player'), (('window',), 'window')):
            with self.subTest(arguments=arguments):
                result = self.run_suite(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [expected])

    def test_all_rejects_player_only_filter_arguments(self):
        result = self.run_suite('all', '-R', 'playback')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


class DesktopSuiteDiscoveryTest(unittest.TestCase):
    """Run the real shell entry point against a temporary project and fake Flutter."""

    def setUp(self):
        import tempfile
        import shutil
        import os
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'integration_test').mkdir()
        (self.root / 'bin').mkdir()
        source = pathlib.Path(__file__).resolve().parents[1] / 'test_native.sh'
        shutil.copyfile(source, self.root / 'scripts/test_native.sh')
        flutter = self.root / 'bin/flutter'
        flutter.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" >> "$CALL_LOG"\nprintf "%s\\n" "$0" > "$CALL_LOG.launcher"\nexit "${FLUTTER_EXIT:-0}"\n')
        flutter.chmod(0o755)
        shutil.copyfile(flutter, self.root / 'bin/flutter.bat')
        (self.root / 'bin/flutter.bat').chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                        CALL_LOG=str(self.root / 'call.log'))

    def run_suite(self, platform='linux', *arguments):
        (self.root / 'call.log').unlink(missing_ok=True)
        return subprocess.run(['bash', str(self.root / 'scripts/test_native.sh'), platform,
                               'desktop', *arguments], cwd=self.root.parent, env=self.env,
                              capture_output=True, text=True, check=False)

    def fixture(self, name):
        (self.root / 'integration_test' / name).write_text('void main() {}\n')

    def test_new_files_are_discovered_without_a_manifest_or_workflow_change(self):
        self.fixture('desktop_window_test.dart')
        self.fixture('android_receiver_test.dart')
        self.fixture('desktop_helper.dart')
        for platform in ('macos', 'linux', 'windows'):
            with self.subTest(platform=platform):
                result = self.run_suite(platform, '--os-input')
                self.assertEqual(result.returncode, 0, result.stderr)
                args = (self.root / 'call.log').read_text().splitlines()
                launcher = 'flutter.bat' if platform == 'windows' else 'flutter'
                self.assertEqual(pathlib.Path((self.root / 'call.log.launcher').read_text().strip()).name, launcher)
                self.assertEqual(args, ['test', '-d', platform,
                    'integration_test/desktop_window_test.dart', '--reporter', 'expanded',
                    '--dart-define=AIRPLAY_OS_INPUT_TEST=true'])
        self.fixture('desktop_future_feature_test.dart')
        result = self.run_suite('linux', '--os-input')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'call.log').read_text().splitlines()
        self.assertEqual(args.count('integration_test/desktop_future_feature_test.dart'), 1)
        self.assertEqual(args.count('integration_test/desktop_window_test.dart'), 1)
        self.assertEqual(args.count('test'), 2)

    def test_input_is_explicit_and_failure_propagates(self):
        self.fixture('desktop_window_test.dart')
        result = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('AIRPLAY_OS_INPUT_TEST=false', (self.root / 'call.log').read_text())
        self.fixture('desktop_second_test.dart')
        self.env['FLUTTER_EXIT'] = '23'
        result = self.run_suite('linux', '--os-input')
        self.assertEqual(result.returncode, 23)
        args = (self.root / 'call.log').read_text().splitlines()
        self.assertEqual(args.count('test'), 2)
        self.assertEqual(result.stderr.count('FAIL:'), 2)

    def test_empty_suite_and_unknown_arguments_fail_before_flutter(self):
        self.assertNotEqual(self.run_suite().returncode, 0)
        self.fixture('desktop_window_test.dart')
        self.assertNotEqual(self.run_suite('linux', '--typo').returncode, 0)
        self.assertNotEqual(self.run_suite('linux', '--os-input', '--typo').returncode, 0)
        self.assertFalse((self.root / 'call.log').exists())


class NativeAllScopeTest(unittest.TestCase):
    def run_suite(self, *arguments):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for build in ('windows-native', 'windows/x64'):
                (root / 'build' / build).mkdir(parents=True)
                (root / 'build' / build / 'CTestTestfile.cmake').touch()
            source = (pathlib.Path(__file__).resolve().parents[1] / 'test_native.sh').read_text()
            definitions, dispatch = source.split('\nif [[ $# -eq 0 ]]; then\n    case "$(uname -s)"', 1)
            script = definitions + '\n' + '''
project_root="$1"
shift
linux_tests() { echo native; }
linux_window() { echo drag; }
alac_tests() { echo alac; }
ctest() { case "$2" in */windows-native) echo native ;; */windows/x64) echo texture ;; esac; }
''' + '\nif [[ $# -eq 0 ]]; then\n    case "$(uname -s)"' + dispatch
            return subprocess.run(['bash', '-c', script, 'native-all', str(root), *arguments],
                                  capture_output=True, text=True, check=False)

    def test_unfiltered_all_keeps_all_former_ci_suites(self):
        for platform, expected in (('linux', ['native', 'drag', 'alac']),
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
