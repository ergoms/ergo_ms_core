"""Шаги setup-full: модульные задачи из vscode.tasks.yaml (include_in)."""

from __future__ import annotations

import subprocess
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
from lifecycle.host import ops as host_ops  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402


class ModuleSetupTasksStep(DeploymentStep):
    """Выполнить задачи модулей с include_in: setup-full (только host)."""

    @property
    def name(self) -> str:
        return 'module_setup_tasks'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    def run(self, ctx: DeploymentContext) -> StepResult:
        # Ленивый import: избегаем цикла recipes → step → module_tasks_loader → lifecycle
        from module_tasks_loader import INCLUDE_SETUP_FULL, tasks_for_target  # noqa: WPS433

        tasks = tasks_for_target(ctx.project_root, INCLUDE_SETUP_FULL)
        if not tasks:
            print(format_console('skip', t('no_module_setup_tasks')))
            return StepResult()

        print(
            format_console(
                'info',
                t('module_setup_tasks_running', count=len(tasks)),
            )
        )
        env = host_ops.api_env(ctx)
        bin_dir = ctx.project_root / 'core' / 'deployment' / 'bin'
        if bin_dir.is_dir():
            sep = ';' if sys.platform == 'win32' else ':'
            existing = env.get('PATH', '')
            env['PATH'] = f'{bin_dir}{sep}{existing}' if existing else str(bin_dir)

        for entry in tasks:
            print(format_console('info', f'{entry.label}: {entry.command}'))
            code = subprocess.call(
                entry.command,
                shell=True,
                cwd=str(ctx.project_root),
                env=env,
            )
            if code != 0:
                print(
                    format_console(
                        'error',
                        t('module_task_failed', label=entry.label, code=code),
                    ),
                    file=sys.stderr,
                )
                return StepResult(
                    exit_code=code,
                    message=t('module_task_exec_failed', command=entry.command),
                )
            print(format_console('ok', entry.label))

        return StepResult()
