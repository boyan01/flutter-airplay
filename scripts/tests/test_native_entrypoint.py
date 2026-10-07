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
