"""Foreground dev-процессы."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.host import ops as host_ops  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402

_DEV_SCRIPTS = {
    'dev-api': [
        'core/api/scripts/warmup_caches_if_needed.py',
        'core/api/scripts/start_api.py',
    ],
    'dev-client': ['core/deployment/scripts/start_client_if_dev.py'],
    'dev-client-enabled': ['core/deployment/scripts/start_client_if_enabled.py'],
    'dev-media': ['core/api/scripts/start_media_api.py'],
    'dev-beat': ['core/api/scripts/start_celery_beat.py'],
    'dev-jupyter': ['core/api/scripts/start_jupyter.py'],
    'warmup-caches-if-needed': ['core/api/scripts/warmup_caches_if_needed.py'],
    'sync-logs-services': ['core/deployment/scripts/sync_vscode_logs_services.py'],
}


class DevForegroundStep(DeploymentStep):
    def __init__(self, recipe_key: str) -> None:
        self._recipe_key = recipe_key

    @property
    def name(self) -> str:
        return f'dev_{self._recipe_key}'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        scripts = _DEV_SCRIPTS.get(self._recipe_key, [])
        if not scripts:
            return StepResult(exit_code=1, message=f'Неизвестный dev-рецепт: {self._recipe_key}')
        code = 0
        for rel in scripts:
            code = host_ops.run_python_script(ctx, rel, prefer_venv=True)
            if code != 0:
                return StepResult(exit_code=code)
        return StepResult()


class DevWorkerStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'dev_worker'

    def run(self, ctx: DeploymentContext) -> StepResult:
        worker = ctx.option_str('worker', 'all')
        script = 'core/api/scripts/start_celery_worker.py'
        py = host_ops.pick_python_for_ctx(ctx)
        script_path = ctx.project_root / script
        import subprocess

        cmd = [*py, str(script_path)]
        if worker:
            cmd.extend(['--worker', worker])
        code = subprocess.call(
            cmd,
            cwd=str(ctx.project_root),
            env=host_ops.api_env(ctx),
        )
        return StepResult(exit_code=code)
