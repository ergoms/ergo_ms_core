"""Матрица изолированных сценариев развёртывания.

Не декартово все ERGO_*: mysql/mssql/smtp/security не меняют топологию запуска.
Службы ОС (NSSM/systemd) живьём не ставим — это перезаписало бы хост.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ScenarioSpec:
    id: str
    launch: str
    proxy: str
    jupyter: str
    db: str
    broker: str
    module_runtime: str

    @property
    def use_nginx(self) -> bool:
        return self.proxy == 'nginx'

    @property
    def use_jupyter(self) -> bool:
        return self.jupyter not in ('', 'none')

    @property
    def use_redis(self) -> bool:
        return self.broker == 'redis'

    @property
    def use_postgres(self) -> bool:
        return self.db == 'postgres'

    @property
    def disable_all_modules(self) -> bool:
        return self.launch == 'host' and self.db == 'sqlite'


def spec_env_overrides(spec: ScenarioSpec) -> dict[str, str]:
    jupyter_mode = spec.jupyter if spec.use_jupyter else 'none'
    return {
        'ERGO_RUNTIME': spec.launch if spec.launch in ('host', 'docker') else 'docker',
        'ERGO_BROKER': spec.broker,
        'ERGO_DB': 'sqlite' if spec.db == 'sqlite' else 'postgres',
        'ERGO_PROXY': spec.proxy,
        'ERGO_JUPYTER': jupyter_mode,
        'ERGO_SEARCH_ENABLED': 'true' if spec.launch == 'docker' else 'false',
        'DOCKER_ENABLED': 'true' if spec.launch == 'docker' else 'false',
        'REDIS_ENABLED': 'true' if spec.use_redis else 'false',
        'NGINX_ENABLED': 'true' if spec.use_nginx else 'false',
        'MODULE_RUNTIME': spec.module_runtime,
        'API_JUPYTER_ACCESS_MODE': jupyter_mode if jupyter_mode != 'none' else 'local',
        'API_HOST': '0.0.0.0' if spec.launch == 'docker' else '127.0.0.1',
    }


def all_specs() -> tuple[ScenarioSpec, ...]:
    return (
        ScenarioSpec(
            'docker_nginx_jupyter',
            'docker',
            'nginx',
            'nginx',
            'postgres',
            'redis',
            'monolith',
        ),
        ScenarioSpec(
            'docker_direct',
            'docker',
            'none',
            'none',
            'postgres',
            'redis',
            'monolith',
        ),
        ScenarioSpec(
            'docker_jupyter_local',
            'docker',
            'none',
            'local',
            'postgres',
            'redis',
            'monolith',
        ),
        ScenarioSpec(
            'docker_microservice',
            'docker',
            'nginx',
            'none',
            'postgres',
            'redis',
            'microservice',
        ),
        ScenarioSpec(
            'host_sqlite_direct',
            'host',
            'none',
            'none',
            'sqlite',
            'local',
            'monolith',
        ),
        ScenarioSpec(
            'host_postgres_redis_nginx',
            'host',
            'nginx',
            'none',
            'postgres',
            'redis',
            'monolith',
        ),
        ScenarioSpec(
            'host_jupyter_local',
            'host',
            'none',
            'local',
            'sqlite',
            'local',
            'monolith',
        ),
    )
