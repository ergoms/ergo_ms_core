"""Изолированный worktree: setup-full без служб ОС."""

from __future__ import annotations

import os
import secrets
import shutil
import subprocess
from pathlib import Path

from project_layout import cache_dir, ensure_dir
from scenario_test.isolation import workspace_config_fingerprint
from scenario_test.ports import pick_scenario_ports
from service_names import PREFIX_ENV

from .environment import IsolatedEnvironment, venv_python
from .processes import start_api, start_client, stop_api, stop_proc


class HostWorktreeEnvironment(IsolatedEnvironment):
    kind = 'host'

    def __init__(self, workspace: Path, run_dir: Path, prefix: str) -> None:
        super().__init__(workspace, run_dir, prefix)
        self._fingerprint = workspace_config_fingerprint(workspace)
        self._used_worktree = False
        self._ports: dict[str, int] = {}
        self._api = None
        self._client = None

    def provision(self) -> None:
        ensure_dir(self.run_dir)
        self._create_tree()
        self._link_download_cache()
        self._write_throwaway_config()
        result = self.run_ergoms('setup-full', timeout=7200)
        if result.returncode != 0:
            detail = ((result.stderr or '') + '\n' + (result.stdout or ''))[-2000:]
            raise RuntimeError(detail or f'setup-full exit {result.returncode}')

    def start(self) -> None:
        python = venv_python(self.tree_root)
        if not python.is_file():
            raise RuntimeError(f'нет venv python: {python}')
        yaml_path = self.tree_root / 'databases.yaml'
        port = int(self._ports.get('api', 18000))
        self._api = start_api(
            self.tree_root,
            yaml_path=yaml_path,
            port=port,
            extra_env={PREFIX_ENV: self.prefix, 'DEBUG': 'false'},
        )

    def start_client(self) -> None:
        if self._client is not None:
            return
        extra = {PREFIX_ENV: self.prefix}
        extra['API_PORT'] = str(self._ports.get('api', 18000))
        extra['CLIENT_PORT'] = str(self._ports.get('client', 18001))
        self._client = start_client(self.tree_root, client_url=self.client_base(), extra_env=extra)

    def http_base(self) -> str:
        port = self._ports.get('api', 8000)
        return f'http://127.0.0.1:{port}'

    def client_base(self) -> str:
        port = self._ports.get('client', 8001)
        return f'http://127.0.0.1:{port}'

    def teardown(self) -> None:
        stop_proc(self._client)
        self._client = None
        stop_api(self._api)
        self._api = None
        try:
            self.run_ergoms('clean', timeout=600)
        except Exception:
            pass
        if self._used_worktree and self.tree_root.is_dir():
            subprocess.run(
                ['git', 'worktree', 'remove', '--force', str(self.tree_root)],
                cwd=str(self.workspace),
                capture_output=True,
                check=False,
            )
        elif self.tree_root.is_dir():
            shutil.rmtree(self.tree_root, ignore_errors=True)
        after = workspace_config_fingerprint(self.workspace)
        if after != self._fingerprint:
            raise RuntimeError('рабочие .env или databases.yaml изменились во время прогона')

    def _create_tree(self) -> None:
        result = subprocess.run(
            ['git', 'worktree', 'add', '--detach', str(self.tree_root), 'HEAD'],
            cwd=str(self.workspace),
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            self._used_worktree = True
            return
        ignore = shutil.ignore_patterns(
            'virtual_env',
            'logs',
            '.git',
            'node_modules',
            '__pycache__',
            '.env',
            'dist',
        )
        shutil.copytree(self.workspace, self.tree_root, ignore=ignore, dirs_exist_ok=True)

    def _link_download_cache(self) -> None:
        source = cache_dir(self.workspace) / 'downloads'
        if not source.is_dir():
            return
        target_parent = ensure_dir(cache_dir(self.tree_root))
        target = target_parent / 'downloads'
        if target.exists():
            return
        try:
            if os.name == 'nt':
                subprocess.run(
                    ['cmd', '/c', 'mklink', '/J', str(target), str(source)],
                    check=False,
                    capture_output=True,
                )
            else:
                target.symlink_to(source, target_is_directory=True)
        except OSError:
            pass

    def _write_throwaway_config(self) -> None:
        ports = pick_scenario_ports()
        if not ports:
            raise RuntimeError('нет свободных портов для изолированного worktree')
        self._ports = ports
        env_text = (
            f'{PREFIX_ENV}={self.prefix}\n'
            'ERGO_RUNTIME=host\n'
            'ERGO_PROXY=none\n'
            'ERGO_BROKER=local\n'
            'ERGO_DB=sqlite\n'
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
