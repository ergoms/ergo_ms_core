"""Изолированный Docker-стек: docker-init / docker-up, не сырой compose."""

from __future__ import annotations

import secrets

from project_layout import ensure_dir
from scenario_test.ports import pick_scenario_ports
from scenario_test.sidecars import docker_available
from service_names import PREFIX_ENV

from .http import wait_http
from .worktree_env import HostWorktreeEnvironment


class SkipEnvironment(RuntimeError):
    """Окружение нельзя поднять — кейс должен стать SKIP, не FAIL."""


class DockerEnvironment(HostWorktreeEnvironment):
    kind = 'docker'

    def __init__(
        self,
        workspace,
        run_dir,
        prefix: str,
        spec_id: str = 'docker_direct',
    ) -> None:
        super().__init__(workspace, run_dir, prefix)
        self.spec_id = spec_id

    def provision(self) -> None:
        if not docker_available():
            raise SkipEnvironment('Docker недоступен — изолированный стек не поднимаем')
        ensure_dir(self.run_dir)
        self._create_tree()
        self._link_download_cache()
        self._write_throwaway_config()
        result = self.run_ergoms('docker-init', timeout=7200)
        if result.returncode != 0:
            detail = ((result.stderr or '') + '\n' + (result.stdout or ''))[-2000:]
            lowered = detail.lower()
            if 'docker' in lowered and ('not found' in lowered or 'не найден' in lowered):
                raise SkipEnvironment('Docker CLI недоступен')
            raise RuntimeError(detail or f'docker-init exit {result.returncode}')

    def start(self) -> None:
        wait_http(self.http_base(), timeout_sec=180.0)

    def start_client(self) -> None:
        wait_http(self.client_base(), timeout_sec=120.0, path='/')

    def teardown(self) -> None:
        try:
            self.run_ergoms('docker-down', '-v', '--remove-orphans', timeout=1800)
        except Exception:
            pass
        HostWorktreeEnvironment.teardown(self)

    def _write_throwaway_config(self) -> None:
        ports = pick_scenario_ports()
        if not ports:
            raise RuntimeError('нет свободных портов для изолированного Docker')
        self._ports = ports
        env_text = (
            f'{PREFIX_ENV}={self.prefix}\n'
            f'DOCKER_COMPOSE_PROJECT={self.prefix}\n'
            f'COMPOSE_PROJECT_NAME={self.prefix}\n'
            'ERGO_RUNTIME=docker\n'
            'ERGO_PROXY=none\n'
            'ERGO_BROKER=redis\n'
            'ERGO_DB=postgres\n'
            'ERGO_SEARCH_ENABLED=false\n'
            'ERGO_JUPYTER=none\n'
            'MODULE_RUNTIME=monolith\n'
            'HOST_PROFILE=full\n'
            f'API_PORT={self._ports.get("api", 18000)}\n'
            f'CLIENT_PORT={self._ports.get("client", 18001)}\n'
            f'API_SECRET_KEY={secrets.token_hex(32)}\n'
            f'API_JWT_SIGNING_KEY={secrets.token_hex(32)}\n'
            'DEBUG=false\n'
        )
        (self.tree_root / '.env').write_text(env_text, encoding='utf-8')
        db_path = (self.run_dir / 'scenario.sqlite3').as_posix()
        (self.tree_root / 'databases.yaml').write_text(
            'default:\n'
            '  engine: sqlite\n'
            f'  name: {db_path}\n',
            encoding='utf-8',
        )
