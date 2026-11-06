"""Runner regression tests; synthetic fixtures verify tooling, not engine performance."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

import run_ecs_bench as bench


class BenchmarkRunnerTests(unittest.TestCase):
    def row(self):
        return dict(mode='gameobject', count=1000, frames=600, threads=1,
                    memory_before=100, memory_after=200,
                    **{key: 1.0 for key in bench.METRICS})

    def test_interleaves_and_reverses_build_order(self):
        self.assertEqual(list(bench.schedule(['baseline', 'current'], [1000], ['gameobject'], 2)),
                         [('baseline', 1000, 'gameobject', 1), ('current', 1000, 'gameobject', 1),
                          ('current', 1000, 'gameobject', 2), ('baseline', 1000, 'gameobject', 2)])

    def test_rejects_missing_duplicate_mismatched_and_invalid_results(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'result.jsonl'
            bad = dict(self.row(), frame_avg_ms=float('nan'))
            for content in ['', json.dumps(self.row()) + '\n' + json.dumps(self.row()),
                            json.dumps(dict(self.row(), count=1)), json.dumps(bad),
                            json.dumps(dict(self.row(), update_avg_ms=-1))]:
                path.write_text(content)
                with self.subTest(content=content), self.assertRaises(ValueError):
                    bench.read_result(path, 'gameobject', 1000, 600)
            path.write_text(json.dumps(self.row()))
            self.assertEqual(bench.read_result(path, 'gameobject', 1000, 600), self.row())

    def test_zero_exit_without_check_success_is_failure(self):
        with patch.object(bench.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
            with self.assertRaisesRegex(ValueError, 'without reporting'):
                bench.run_one(Path('/fake'), Path('/tmp'), 'check', 1, 1, 1)

    def test_nonzero_exit_is_failure_even_with_success_text(self):
        result = subprocess.CompletedProcess([], 1, 'EcsBench checks: all passed', 'crash')
        with patch.object(bench.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(ValueError, 'Exit 1'):
                bench.run_one(Path('/fake'), Path('/tmp'), 'check', 1, 1, 1)

    def test_each_process_has_isolated_output_and_explicit_settings(self):
        paths = []
        def fake_run(command, **kwargs):
            env = kwargs['env']
            paths.append(env['TALLOW_BENCH_OUT'])
            self.assertEqual(env['TALLOW_BENCH_EXPLORER'], '0')
            self.assertEqual(env['TALLOW_BENCH_FRAMES'], '600')
            Path(paths[-1]).write_text(json.dumps(self.row()))
            return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(bench.subprocess, 'run', side_effect=fake_run):
            for _ in range(2):
                self.assertEqual(bench.run_one(Path('/fake'), Path('/tmp'), 'gameobject', 1000, 600, 1), self.row())
        self.assertNotEqual(*paths)


if __name__ == '__main__':
    unittest.main()
