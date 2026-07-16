"""Службы ОС — шаги pipeline."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.host.shell_bridge import invoke_dispatch  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402

_SERVICE_OPS = {
    'install': {
        'all': 'install-all',
        'api': 'install-api',
        'client': 'install-client',
        'media': 'install-media',
        'beat': 'install-beat',
        'workers': 'install-workers',
    },
    'start': {
        'all': 'start-all',
        'api': 'start-api',
        'client': 'start-client',
        'media': 'start-media',
        'beat': 'start-beat',
        'workers': 'start-workers',
    },
    'stop': {
        'all': 'stop-all',
        'api': 'stop-api',
        'client': 'stop-client',
        'media': 'stop-media',
        'beat': 'stop-beat',
        'workers': 'stop-workers',
    },
    'restart': {
        'all': 'restart-all',
        'api': 'restart-api',
        'client': 'restart-client',
        'media': 'restart-media',
        'beat': 'restart-beat',
        'workers': 'restart-workers',
    },
    'status': {
        'all': 'status-all',
        'api': 'status-api',
        'client': 'status-client',
        'media': 'status-media',
        'beat': 'status-beat',
        'workers': 'status-workers',
    },
    'uninstall': {'all': 'uninstall-all'},
}


class ServiceOperationStep(DeploymentStep):
    def __init__(self, operation: str, service_id: str = 'all') -> None:
        self._operation = operation
        self._service_id = service_id

    @property
    def name(self) -> str:
        return f'service_{self._operation}_{self._service_id}'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        op_map = _SERVICE_OPS.get(self._operation, {})
        dispatch_op = op_map.get(self._service_id)
        if not dispatch_op:
            return StepResult(exit_code=1, message=f'Неизвестная операция службы: {self._operation}/{self._service_id}')
        extra: list[str] = []
        if self._operation == 'uninstall' and ctx.option_bool('purge'):
            extra.append('--purge')
        code = invoke_dispatch(ctx, 'service', dispatch_op, *extra)
        return StepResult(exit_code=code)
