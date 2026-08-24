from __future__ import annotations

import unittest
from pathlib import Path

import _bootstrap  # noqa: F401

from lifecycle.recipes import RECIPE_REGISTRY  # noqa: E402
from lifecycle.steps.dev_steps import _DEV_SCRIPTS  # noqa: E402
from lifecycle.steps.infra_steps import EnsureNginxOsServiceStep  # noqa: E402
from lifecycle.steps.service_steps import ServiceOperationStep  # noqa: E402
from scenario_test.matrix import all_specs, spec_env_overrides  # noqa: E402


class ScenarioMatrixTests(unittest.TestCase):
    def test_matrix_covers_launch_proxy_jupyter_db_broker_runtime(self) -> None:
        specs = all_specs()
        self.assertGreaterEqual(len(specs), 7)
        launches = {item.launch for item in specs}
        proxies = {item.proxy for item in specs}
        jupyter = {item.jupyter for item in specs}
        dbs = {item.db for item in specs}
        brokers = {item.broker for item in specs}
        runtimes = {item.module_runtime for item in specs}
        self.assertEqual(launches, {'docker', 'host'})
        self.assertEqual(proxies, {'nginx', 'none'})
        self.assertEqual(jupyter, {'nginx', 'none', 'local'})
        self.assertEqual(dbs, {'postgres', 'sqlite'})
        self.assertEqual(brokers, {'redis', 'local'})
        self.assertEqual(runtimes, {'monolith', 'microservice'})

    def test_spec_env_overrides_do_not_use_host_ports(self) -> None:
        for spec in all_specs():
            values = spec_env_overrides(spec)
            joined = ' '.join(values.values())
            self.assertNotIn('8000', joined)
            self.assertNotIn('5433', joined)
            self.assertNotIn('6379', joined)
            if spec.launch == 'host':
                self.assertEqual(values['API_HOST'], '127.0.0.1')
            else:
                self.assertEqual(values['API_HOST'], '0.0.0.0')

    def test_service_start_all_uses_service_operation(self) -> None:
        start = RECIPE_REGISTRY['service-start-all']
        self.assertTrue(any(isinstance(step, ServiceOperationStep) for step in start.steps))
        install = RECIPE_REGISTRY['service-install-all']
        self.assertTrue(any(isinstance(step, ServiceOperationStep) for step in install.steps))
        self.assertTrue(any(isinstance(step, EnsureNginxOsServiceStep) for step in install.steps))

    def test_dev_and_nssm_call_same_start_scripts(self) -> None:
        self.assertTrue(any(item.endswith('start_api.py') for item in _DEV_SCRIPTS['dev-api']))
        self.assertTrue(any(item.endswith('start_media_api.py') for item in _DEV_SCRIPTS['dev-media']))
        self.assertTrue(any(item.endswith('start_jupyter.py') for item in _DEV_SCRIPTS['dev-jupyter']))
        nssm = Path(__file__).resolve().parents[1] / 'windows' / 'lib' / 'nssm.ps1'
        text = nssm.read_text(encoding='utf-8')
        self.assertIn('start_api.py', text)
        self.assertIn('start_media_api.py', text)


if __name__ == '__main__':
    unittest.main()
