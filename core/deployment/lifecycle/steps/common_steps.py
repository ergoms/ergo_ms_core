"""Общие шаги deploy (host + docker)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402
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
        print(format_console('info', t('installing_python_deps')))
        args: list[str] = ['install']
        if ctx.option_bool('force'):
            args.append('--force')
        code = host_ops.run_api_command(ctx, *args)
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message=t('docker_not_found_short'))
        print(format_console('info', t('installing_python_deps')))
        print(
            format_console(
                'info',
                t('python_install_progress', path=docker_ops.DOCKER_PYTHON_INSTALL_LOG),
            )
        )
        code = docker_ops.run_api_oneoff(docker_ops.api_install_shell(), mode=ctx.docker_mode)
        if code != 0:
            print(
                format_console(
                    'error',
                    t('python_install_failed_log', path=docker_ops.DOCKER_PYTHON_INSTALL_LOG),
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
        if not ctx.option_bool('force') and host_ops.host_npm_deps_up_to_date(ctx.project_root):
            print(format_console('skip', t('npm_deps_already_installed_skip')))
            return StepResult()
        print(format_console('info', t('installing_npm_deps')))
        code = host_ops.run_npm(ctx, 'install:all')
        if code == 0:
            host_ops.touch_host_npm_deps_marker(ctx.project_root)
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message=t('docker_not_found_short'))
        resolved_mode = ctx.resolved_docker_mode()
        service = docker_ops.npm_client_service(resolved_mode)
        shell = (
            'mkdir -p /app/logs/docker '
            '&& ERGO_DOCKER_SERVICE_NAME=client DOCKER_NPM_INSTALL=always '
            '/usr/local/bin/ergo-ensure-npm-deps.sh '
            '2>&1 | tee -a /app/logs/docker/npm-install.log'
        )
        print(format_console('info', t('installing_npm_deps_service', service=service)))
        print(format_console('info', t('npm_progress_docker_log')))
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
        print(format_console('info', t('applying_migrations')))
        code = host_ops.run_api_command(ctx, 'migrate')
        return StepResult(exit_code=code)

    def _run_docker(self, ctx: DeploymentContext) -> StepResult:
        if not docker_ops.find_docker_compose():
            return StepResult(exit_code=1, message=t('docker_not_found_short'))
        print(format_console('info', t('migrations_ellipsis')))
        code = docker_ops.run_api_oneoff(docker_ops.api_migrate_shell(), mode=ctx.docker_mode)
        return StepResult(exit_code=code)


class WarmupCachesStep(DeploymentStep):
    def __init__(self, *, if_needed: bool = False) -> None:
        self._if_needed = if_needed

    @property
    def name(self) -> str:
        return 'warmup_caches'

    def run(self, ctx: DeploymentContext) -> StepResult:
        if ctx.runtime == 'docker':
            if not docker_ops.find_docker_compose():
                return StepResult(exit_code=1, message=t('docker_not_found_short'))
            code = docker_ops.run_api_oneoff(docker_ops.api_warmup_shell(), mode=ctx.docker_mode)
            return StepResult(exit_code=code)
        if self._if_needed:
            code = host_ops.run_python_script(
                ctx,
                'core/api/scripts/warmup_caches_if_needed.py',
            )
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
        if not ctx.option_bool('force') and host_ops.client_build_up_to_date(
            ctx.project_root, ctx.raw_env
        ):
            print(format_console('skip', t('client_build_already_fresh_skip')))
            return StepResult()
        print(format_console('info', t('building_client')))
        code = host_ops.run_npm(ctx, 'build')
        if code == 0:
            host_ops.write_client_build_stamp(ctx.project_root, ctx.raw_env)
        return StepResult(exit_code=code)


class CollectStaticStep(DeploymentStep):
    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.runtime == 'host'

    @property
    def name(self) -> str:
        return 'collectstatic'

    def run(self, ctx: DeploymentContext) -> StepResult:
        print(format_console('info', t('collecting_static')))
        code = host_ops.run_api_command(ctx, 'collectstatic', '--noinput')
        return StepResult(exit_code=code)
