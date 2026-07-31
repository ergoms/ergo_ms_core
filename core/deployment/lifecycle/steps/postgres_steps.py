"""Ensure portable PostgreSQL for setup-full."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = _DEPLOYMENT_DIR / 'scripts'
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.host.shell_bridge import invoke_dispatch  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402


class EnsurePostgresStep(DeploymentStep):
    """Если нет системной службы PostgreSQL — установить portable и создать БД."""

    @property
    def name(self) -> str:
        return 'ensure_postgres'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import (  # noqa: WPS433
            is_postgres_force_install,
            should_setup_portable_postgres,
        )
        from install_postgres import has_system_postgresql_service, is_installed  # noqa: WPS433

        force = ctx.option_bool('with_postgres') or is_postgres_force_install()
        if not force and not should_setup_portable_postgres():
            print(format_console(
                'skip',
                t('postgres_skip_not_portable'),
            ))
            return StepResult()

        if has_system_postgresql_service() and not force:
            print(format_console('skip', t('postgres_system_service_skip')))
            return StepResult()

        if force and has_system_postgresql_service():
            from postgres_common import (  # noqa: WPS433
                resolve_portable_listen_port,
            )

            listen_port = resolve_portable_listen_port(ctx.project_root)
            print(format_console(
                'warning',
                t('postgres_force_with_system', listen_port=listen_port),
            ))

        if is_installed(ctx.project_root) and not force:
            print(format_console('info', t('postgres_portable_found')))

        print(format_console('info', t('installing_portable_postgres')))
        extra: list[str] = []
        if force:
            extra.append('--no-skip-system')
        # Install-Postgres в shell читает Extra; для --no-skip-system передаём через python напрямую
        # если shell не знает флаг — вызываем python install с флагом через dispatch install
        # и дополнительно прокидываем в Extra для совместимости
        code = invoke_dispatch(ctx, 'postgres', 'install', *extra)
        if code != 0:
            return StepResult(
                exit_code=code,
                message=t('postgres_portable_install_failed'),
            )
        print(format_console('ok', t('postgres_ready')))
        return StepResult()
