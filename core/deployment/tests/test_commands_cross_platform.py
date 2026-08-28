from __future__ import annotations

import re
import unittest
from pathlib import Path

import _bootstrap  # noqa: F401

from lifecycle.recipes import RECIPE_REGISTRY  # noqa: E402

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
_COMMANDS_CONF = _DEPLOYMENT_DIR / 'commands.conf'
_PS1 = _DEPLOYMENT_DIR / 'windows' / 'ergo_ms.ps1'
_SH = _DEPLOYMENT_DIR / 'linux' / 'ergo_ms.sh'

_WIN_LINUX_COMMANDS = (
    'docker-up',
    'docker-down',
    'docker-build',
    'docker-init',
    'docker-loadtest-up',
    'docker-loadtest-down',
    'deployment-test',
    'deployment-scenario-test',
)

_RECIPE_NAMES = (
    'nginx-install',
    'nginx-test',
    'service-install-all',
    'service-start-all',
    'docker-init',
    'docker-up',
    'docker-build',
)

_HOST_BUILTIN = (
    'install-nginx',
    'test-nginx',
    'start-nginx',
    'install-services',
    'start',
)


def _parse_commands(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            continue
        name, body = line.split('=', 1)
        result[name.strip()] = body.strip()
    return result


def _has_platform_arm(body: str, prefix: str) -> bool:
    return re.search(rf'(?:^|&&)\s*{re.escape(prefix)}', body) is not None


class CommandsCrossPlatformTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.conf = _parse_commands(_COMMANDS_CONF.read_text(encoding='utf-8'))
        cls.ps1 = _PS1.read_text(encoding='utf-8')
        cls.sh = _SH.read_text(encoding='utf-8')

    def test_docker_commands_have_win_and_linux_arms(self) -> None:
        for name in _WIN_LINUX_COMMANDS:
            with self.subTest(name=name):
                self.assertIn(name, self.conf)
                body = self.conf[name]
                self.assertTrue(_has_platform_arm(body, 'win:'), msg=f'{name} missing win:')
                self.assertTrue(_has_platform_arm(body, 'linux:'), msg=f'{name} missing linux:')

    def test_lifecycle_recipes_registered(self) -> None:
        for name in _RECIPE_NAMES:
            with self.subTest(name=name):
                self.assertIn(name, RECIPE_REGISTRY)

    def test_host_nginx_and_services_exist_on_both_os_wrappers(self) -> None:
        for name in _HOST_BUILTIN:
            with self.subTest(name=name):
                self.assertIn(name, self.ps1)
                self.assertIn(name, self.sh)

    def test_recipe_aliases_for_install_and_start(self) -> None:
        self.assertIs(RECIPE_REGISTRY['install-nginx'], RECIPE_REGISTRY['nginx-install'])
        self.assertIs(RECIPE_REGISTRY['install-services'], RECIPE_REGISTRY['service-install-all'])
        self.assertIs(RECIPE_REGISTRY['start'], RECIPE_REGISTRY['service-start-all'])
        self.assertIs(RECIPE_REGISTRY['test-nginx'], RECIPE_REGISTRY['nginx-test'])


if __name__ == '__main__':
    unittest.main()
