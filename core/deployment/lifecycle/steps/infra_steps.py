"""Инфраструктура: nginx, redis, tls."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

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
        if self._component == 'nginx' and self._operation == 'install':
            extra.extend([
                ctx.option_str('server_name'),
                ctx.option_str('listen_port'),
            ])
        if self._component == 'redis' and self._operation == 'install':
            port = ctx.option_str('listen_port')
            if port:
                extra.append(port)
        if self._component == 'tls' and self._operation == 'install':
            extra.extend([
                ctx.option_str('domain'),
                ctx.option_str('email'),
            ])
        ctx.options.setdefault('needs_sudo', self._component in ('nginx', 'redis', 'tls'))
        code = invoke_dispatch(ctx, self._component, self._operation, *extra)
        return StepResult(exit_code=code)
