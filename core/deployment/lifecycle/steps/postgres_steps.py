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
        from deployment_env import is_postgres_force_install  # noqa: WPS433
        from install_postgres import has_system_postgresql_service, is_installed  # noqa: WPS433

        force = ctx.option_bool('with_postgres') or is_postgres_force_install()

        if has_system_postgresql_service() and not force:
            print(format_console('skip', 'Системная служба PostgreSQL уже есть'))
            return StepResult()

        if force and has_system_postgresql_service():
            print(format_console(
                'warning',
                'POSTGRES_FORCE_INSTALL / --with-postgres: portable при системной службе',
            ))

        if is_installed(ctx.project_root) and not force:
            print(format_console('info', 'Portable PostgreSQL найден — проверка службы и БД'))

        print(format_console('info', 'Установка / проверка portable PostgreSQL…'))
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
                message='Не удалось установить portable PostgreSQL',
            )
        print(format_console('ok', 'PostgreSQL готов'))
        return StepResult()
