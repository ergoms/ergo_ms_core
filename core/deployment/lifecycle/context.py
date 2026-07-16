"""Контекст развёртывания: read-only env и каталог модулей."""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Literal

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from env_resolvers import read_env_file  # noqa: E402

from lifecycle.modules.catalog import ModuleCatalog  # noqa: E402


class HostPlatform(str, Enum):
    WIN32 = 'win32'
    LINUX = 'linux'
    DARWIN = 'darwin'
    OTHER = 'other'

    @classmethod
    def current(cls) -> HostPlatform:
        if sys.platform == 'win32':
            return cls.WIN32
        if sys.platform == 'darwin':
            return cls.DARWIN
        if sys.platform.startswith('linux'):
            return cls.LINUX
        return cls.OTHER


DeploymentTarget = Literal['deployment', 'service', 'infra', 'compose', 'foreground', 'aux']


@dataclass
class DeploymentContext:
    project_root: Path
    platform: HostPlatform
    runtime: Literal['host', 'docker']
    docker_mode: str | None
    raw_env: dict[str, str]
    module_catalog: ModuleCatalog
    target: DeploymentTarget = 'deployment'
    options: dict[str, Any] = field(default_factory=dict)
    extra_services: list[str] = field(default_factory=list)

    @classmethod
    def create(
        cls,
        project_root: Path,
        *,
        runtime: Literal['host', 'docker'] = 'docker',
        docker_mode: str | None = None,
        raw_env: dict[str, str] | None = None,
        target: DeploymentTarget = 'deployment',
        options: dict[str, Any] | None = None,
    ) -> DeploymentContext:
        root = project_root.resolve()
        env = dict(raw_env) if raw_env is not None else read_env_file(root / '.env')
        if docker_mode:
            env = dict(env)
            env['DOCKER_MODE'] = docker_mode
        return cls(
            project_root=root,
            platform=HostPlatform.current(),
            runtime=runtime,
            docker_mode=docker_mode,
            raw_env=env,
            module_catalog=ModuleCatalog.from_env(root, env),
            target=target,
            options=dict(options or {}),
        )

    def option_bool(self, key: str, default: bool = False) -> bool:
        value = self.options.get(key, default)
        if isinstance(value, bool):
            return value
        if value is None:
            return default
        return str(value).strip().lower() in ('1', 'true', 'yes', 'on')

    def option_str(self, key: str, default: str = '') -> str:
        value = self.options.get(key, default)
        return '' if value is None else str(value)

    def resolved_docker_mode(self) -> str:
        if self.docker_mode:
            return self.docker_mode
        mode = self.raw_env.get('DOCKER_MODE', 'dev').strip().lower()
        return mode if mode in ('dev', 'prod') else 'dev'

    def load_celery_workers_config(self) -> dict[str, Any]:
        docker_dir = self.project_root / 'core' / 'deployment' / 'docker'
        if str(docker_dir) not in sys.path:
            sys.path.insert(0, str(docker_dir))
        from generate_workers_compose import load_workers_config  # noqa: WPS433

        return load_workers_config()
