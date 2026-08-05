"""Инфраструктура: nginx, redis, tls."""

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


class InfraOperationStep(DeploymentStep):
    def __init__(self, component: str, operation: str) -> None:
        self._component = component
        self._operation = operation

    @property
    def name(self) -> str:
        return f'infra_{self._component}_{self._operation}'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        extra: list[str] = []
        if self._operation == 'uninstall' and ctx.option_bool('purge'):
            extra.append('--purge')
        if self._operation == 'renew' and ctx.option_bool('dry_run'):
            extra.append('--dry-run')
        if self._component == 'nginx' and self._operation in ('install', 'install-service'):
            extra.extend([
                ctx.option_str('server_name'),
                ctx.option_str('listen_port'),
            ])
        if self._component == 'redis' and self._operation in ('install', 'install-service'):
            port = ctx.option_str('listen_port')
            if port:
                extra.append(port)
        if self._component == 'postgres' and self._operation == 'install':
            port = ctx.option_str('listen_port')
            if port:
                extra.append(port)
            if ctx.option_bool('with_postgres') or ctx.option_bool('no_skip_system'):
                extra.append('--no-skip-system')
        if self._component == 'postgres' and self._operation == 'migrate-to-portable':
            source_port = ctx.option_str('source_port')
            if source_port:
                extra.extend(['--source-port', source_port])
            source_host = ctx.option_str('source_host')
            if source_host:
                extra.extend(['--source-host', source_host])
            source_user = ctx.option_str('source_user')
            if source_user:
                extra.extend(['--source-user', source_user])
            source_password = ctx.option_str('source_password')
            if source_password:
                extra.extend(['--source-password', source_password])
            if ctx.option_bool('force'):
                extra.append('--force')
            if ctx.option_bool('dry_run'):
                extra.append('--dry-run')
        if self._component == 'tls' and self._operation == 'install':
            extra.extend([
                ctx.option_str('domain'),
                ctx.option_str('email'),
            ])
        if self._component == 'postgres' and self._operation == 'migrate-to-portable':
            ctx.options['needs_sudo'] = False
        else:
            ctx.options.setdefault(
                'needs_sudo',
                self._component in ('nginx', 'redis', 'postgres', 'tls', 'meilisearch'),
            )
        code = invoke_dispatch(ctx, self._component, self._operation, *extra)
        return StepResult(exit_code=code)


class EnsureRedisStep(DeploymentStep):
    """При ERGO_BROKER=redis (или REDIS_ENABLED) — установить portable Redis (setup-full)."""

    @property
    def name(self) -> str:
        return 'ensure_redis'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_redis_enabled  # noqa: WPS433

        if not is_redis_enabled():
            print(format_console(
                'skip',
                t('redis_skip_broker'),
            ))
            return StepResult()

        print(format_console('info', t('installing_redis')))
        ctx.options.setdefault('needs_sudo', True)
        code = invoke_dispatch(ctx, 'redis', 'install')
        if code != 0:
            return StepResult(exit_code=code, message=t('redis_install_failed'))
        print(format_console('ok', t('redis_ready')))
        return StepResult()


class EnsureNginxStep(DeploymentStep):
    """При ERGO_PROXY=nginx (или NGINX_ENABLED) — установить portable nginx (setup-full)."""

    @property
    def name(self) -> str:
        return 'ensure_nginx'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_nginx_enabled  # noqa: WPS433

        if not is_nginx_enabled():
            print(format_console(
                'skip',
                t('nginx_skip_proxy'),
            ))
            return StepResult()

        print(format_console('info', t('installing_nginx')))
        ctx.options.setdefault('needs_sudo', True)
        code = invoke_dispatch(ctx, 'nginx', 'install')
        if code != 0:
            return StepResult(exit_code=code, message=t('nginx_install_failed'))
        print(format_console('ok', t('nginx_ready')))
        return StepResult()


class EnsureMeilisearchStep(DeploymentStep):
    """При ERGO_SEARCH_ENABLED — установить portable Meilisearch (setup-full)."""

    @property
    def name(self) -> str:
        return 'ensure_meilisearch'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_search_enabled  # noqa: WPS433

        if not is_search_enabled():
            print(format_console('skip', t('meilisearch_skip_search')))
            return StepResult()

        print(format_console('info', t('installing_meilisearch')))
        code = invoke_dispatch(ctx, 'meilisearch', 'install')
        if code != 0:
            return StepResult(exit_code=code, message=t('meilisearch_install_failed'))
        print(format_console('ok', t('meilisearch_ready')))
        return StepResult()


class EnsureMeilisearchOsServiceStep(DeploymentStep):
    """При ERGO_SEARCH_ENABLED — зарегистрировать Meilisearch как службу ОС (install-services)."""

    @property
    def name(self) -> str:
        return 'ensure_meilisearch_os_service'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_search_enabled  # noqa: WPS433

        if not is_search_enabled():
            print(format_console('skip', t('meilisearch_service_skip')))
            return StepResult()

        print(format_console('info', t('installing_meilisearch_service')))
        ctx.options.setdefault('needs_sudo', True)
        code = invoke_dispatch(ctx, 'meilisearch', 'install-service')
        if code != 0:
            return StepResult(exit_code=code, message=t('meilisearch_service_install_failed'))
        print(format_console('ok', t('meilisearch_service_ready')))
        return StepResult()


class EnsureRedisOsServiceStep(DeploymentStep):
    """При REDIS_ENABLED=true — зарегистрировать Redis как службу ОС (install-services)."""

    @property
    def name(self) -> str:
        return 'ensure_redis_os_service'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_redis_enabled  # noqa: WPS433

        if not is_redis_enabled():
            print(format_console(
                'skip',
                t('redis_service_skip'),
            ))
            return StepResult()

        print(format_console('info', t('installing_redis_service')))
        ctx.options.setdefault('needs_sudo', True)
        code = invoke_dispatch(ctx, 'redis', 'install-service')
        if code != 0:
            return StepResult(exit_code=code, message=t('redis_service_install_failed'))
        print(format_console('ok', t('redis_service_ready')))
        return StepResult()


class EnsureNginxOsServiceStep(DeploymentStep):
    """При NGINX_ENABLED=true — зарегистрировать nginx как службу ОС (install-services)."""

    @property
    def name(self) -> str:
        return 'ensure_nginx_os_service'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        from deployment_env import is_nginx_enabled  # noqa: WPS433

        if not is_nginx_enabled():
            print(format_console(
                'skip',
                t('nginx_service_skip'),
            ))
            return StepResult()

        print(format_console('info', t('installing_nginx_service')))
        ctx.options.setdefault('needs_sudo', True)
        code = invoke_dispatch(ctx, 'nginx', 'install-service')
        if code != 0:
            return StepResult(exit_code=code, message=t('nginx_service_install_failed'))
        print(format_console('ok', t('nginx_service_ready')))
        return StepResult()
