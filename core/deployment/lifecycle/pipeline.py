"""Последовательный запуск шагов развёртывания."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402


class DeploymentPipeline:
    def __init__(self, steps: list[DeploymentStep]) -> None:
        self._steps = list(steps)

    def run(self, ctx: DeploymentContext) -> int:
        main = [step for step in self._steps if not step.run_as_cleanup]
        cleanup = [step for step in self._steps if step.run_as_cleanup]
        exit_code = 0
        try:
            for step in main:
                if not step.should_run(ctx):
                    continue
                result = step.run(ctx)
                if not result.ok:
                    if result.message:
                        print(format_console('error', result.message), file=sys.stderr)
                    exit_code = result.exit_code
                    break
        finally:
            for step in cleanup:
                if not step.should_run(ctx):
                    continue
                result = step.run(ctx)
                if not result.ok:
                    if result.message:
                        print(format_console('error', result.message), file=sys.stderr)
                    # Ошибка cleanup не затирает код основного сбоя; при успехе основного — пробрасываем.
                    if exit_code == 0:
                        exit_code = result.exit_code
        return exit_code
