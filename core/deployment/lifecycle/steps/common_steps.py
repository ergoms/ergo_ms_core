"""Общие шаги deploy (host + docker)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

from lifecycle.context import DeploymentContext  # noqa: E402
from lifecycle.docker import ops as docker_ops  # noqa: E402
from lifecycle.host import ops as host_ops  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402


class PythonInstallStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'python_install'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if ctx.runtime == 'docker':
            return self._run_docker(ctx)
        return self._run_host(ctx)

    def _run_host(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', 'Установка Python-зависимостей (ядро + модули)…'))
        code = host_ops.run_api_command(ctx, 'install')
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message='Docker не найден.')
        print(format_console('info', 'Установка Python-зависимостей (ядро + модули)…'))
        print(
            format_console(
                'info',
                f'Прогресс — в этом терминале и в {docker_ops.DOCKER_PYTHON_INSTALL_LOG}',
            )
        )
        code = docker_ops.run_api_oneoff(docker_ops.api_install_shell(), mode=ctx.docker_mode)
        if code != 0:
            print(
                format_console(
                    'error',
                    f'Установка Python прервалась. Журнал: {docker_ops.DOCKER_PYTHON_INSTALL_LOG}',
                ),
                file=sys.stderr,
            )
        return StepResult(exit_code=code)


class NpmInstallStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'npm_install'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if ctx.runtime == 'docker':
            return self._run_docker(ctx)
        return self._run_host(ctx)

    def _run_host(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', 'Установка npm-зависимостей…'))
        code = host_ops.run_npm(ctx, 'install:all')
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message='Docker не найден.')
        resolved_mode = ctx.resolved_docker_mode()
        service = docker_ops.npm_client_service(resolved_mode)
        shell = (
            'mkdir -p /app/logs/docker '
            '&& ERGO_DOCKER_SERVICE_NAME=client DOCKER_NPM_INSTALL=always '
            '/usr/local/bin/ergo-ensure-npm-deps.sh '
            '2>&1 | tee -a /app/logs/docker/npm-install.log'
        )
        print(format_console('info', f'Установка npm-зависимостей ({service})…'))
        print(format_console('info', 'Прогресс npm — в logs/docker/npm-install.log (первый запуск может занять несколько минут)'))
        cmd, cwd = docker_ops.build_compose_cmd(
            'run',
            mode=ctx.docker_mode,
            extra_args=['--rm', '--no-deps', '-T', service, 'bash', '-o', 'pipefail', '-c', shell],
            project_root=ctx.project_root,
        )
        code = subprocess.call(cmd, cwd=str(cwd))
        return StepResult(exit_code=code)


class MigrateStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'migrate'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if ctx.runtime == 'docker':
            return self._run_docker(ctx)
        return self._run_host(ctx)

    def _run_host(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', 'Применение миграций…'))
        code = host_ops.run_api_command(ctx, 'migrate')
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message='Docker не найден.')
        print(format_console('info', 'Миграции…'))
        code = docker_ops.run_api_oneoff(docker_ops.api_migrate_shell(), mode=ctx.docker_mode)
        return StepResult(exit_code=code)


class WarmupCachesStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'warmup_caches'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if ctx.runtime == 'docker':
            if not docker_ops.find_docker_compose():
                return StepResult(exit_code=1, message='Docker не найден.')
            code = docker_ops.run_api_oneoff(docker_ops.api_warmup_shell(), mode=ctx.docker_mode)
            return StepResult(exit_code=code)
        code = host_ops.run_api_command(ctx, 'warmup_caches')
        return StepResult(exit_code=code)


class ClientBuildStep(DeploymentStep):
    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    @property
    def name(self) -> str:
        return 'client_build'

    def run(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', 'Сборка клиента…'))
        code = host_ops.run_npm(ctx, 'build')
        return StepResult(exit_code=code)


class CollectStaticStep(DeploymentStep):
    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    @property
    def name(self) -> str:
        return 'collectstatic'

    def run(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', 'Сбор статических файлов…'))
        code = host_ops.run_api_command(ctx, 'collectstatic', '--noinput')
        return StepResult(exit_code=code)
