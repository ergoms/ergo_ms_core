"""Имена шагов ergoms ci не запускают сами проверки."""

from __future__ import annotations

import unittest
from pathlib import Path

import _bootstrap  # noqa: F401

from run_ci import FAST_STEP_LABELS, client_test_files, nightly_step_labels  # noqa: E402


class RunCiStepLabelTests(unittest.TestCase):
    def test_fast_labels_are_unique(self) -> None:
        self.assertEqual(
            FAST_STEP_LABELS,
            (
                'poetry.lock',
                'package-lock.json',
                'core-rules-check',
                'system-test unit',
                'lint:check',
                'client-tests',
            ),
        )
        self.assertEqual(len(FAST_STEP_LABELS), len(set(FAST_STEP_LABELS)))

    def test_nightly_scenario_labels_include_spec(self) -> None:
        labels = nightly_step_labels()
        self.assertEqual(
            labels,
            (
                'system-test scenarios host_sqlite_direct',
                'system-test scenarios docker_direct',
                'system-test security',
                'system-test browser',
            ),
        )
        scenarios = [label for label in labels if 'scenarios' in label]
        self.assertEqual(len(scenarios), 2)
        self.assertIn('host_sqlite_direct', scenarios[0])
        self.assertIn('docker_direct', scenarios[1])

    def test_disabled_module_client_tests_are_left_out(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw:
            root = Path(raw)
            kept = root / 'modules' / 'kept_mod' / 'client' / 'tests'
            skipped = root / 'modules' / 'paused_mod' / 'client' / 'tests'
            kept.mkdir(parents=True)
            skipped.mkdir(parents=True)
            (kept / 'alive.test.mjs').write_text('export {}\n', encoding='utf-8')
            (skipped / 'paused.test.mjs').write_text('export {}\n', encoding='utf-8')
            files = client_test_files(root, disabled=frozenset({'paused_mod'}))
        self.assertEqual([path.name for path in files], ['alive.test.mjs'])


if __name__ == '__main__':
    unittest.main()
