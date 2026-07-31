"""Docker Compose шаги (up/down/build/logs/ps)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from env_resolvers import read_env_file  # noqa: E402

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.docker import ops as docker_ops  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402


class DockerComposeCommandStep(DeploymentStep):
    def __init__(self, compose_command: str, extra_args: list[str] | None = None) -> None:
        self._compose_command = compose_command
        self._extra_args = extra_args or []

    @property
    def name(self) -> str:
        return f'docker_compose_{self._compose_command}'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'docker'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message=t('docker_not_found_short'))
        extra = list(ctx.options.get('compose_extra_args', [])) or list(self._extra_args)
        cmd, cwd = docker_ops.build_compose_cmd(
            self._compose_command,
            mode=ctx.docker_mode,
            extra_args=extra,
            project_root=ctx.project_root,
        )
        env = None
        if self._compose_command == 'build':
            env = docker_ops.build_subprocess_env(ctx.raw_env)
        code = subprocess.call(cmd, cwd=str(cwd), env=env)
        return StepResult(exit_code=code)


class DockerComposeUpStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'docker_compose_up'

    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'docker'

    def run(self, ctx: DeploymentContext) -> StepResult:
        root = ctx.project_root
        if docker_ops.setup_marker_exists(root):
            step = DockerComposeCommandStep('up', ['-d', *ctx.extra_services])
            return step.run(ctx)
        print(format_console('info', t('docker_bootstrap_infra_up')))
        from lifecycle.orchestrator import DeploymentOrchestrator  # noqa: WPS433

        code = DeploymentOrchestrator(root).run_recipe(
            'docker-bootstrap',
            runtime='docker',
            docker_mode=ctx.docker_mode,
            extra_services=ctx.extra_services,
        )
        return StepResult(exit_code=code)


class DockerComposeRestartStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'docker_compose_restart'

    def run(self, ctx: DeploymentContext) -> StepResult:
        down = DockerComposeCommandStep('down')
        result = down.run(ctx)
        if not result.ok:
            return result
        up = DockerComposeUpStep()
        return up.run(ctx)
