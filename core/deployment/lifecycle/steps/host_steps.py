"""Host-шаги setup (submodules, venv, scaffold, cli)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

from lifecycle.context import DeploymentContext, HostPlatform  # noqa: E402
from lifecycle.host import ops as host_ops  # noqa: E402
from lifecycle.host.shell_bridge import invoke_dispatch  # noqa: E402
from lifecycle.steps.base import DeploymentStep, StepResult  # noqa: E402

DEFAULT_CORE_SUBMODULES = ('core/api', 'core/client', 'core/media_api')


class HostExecutionPolicyStep(DeploymentStep):
    def should_run(self, ctx: DeploymentContext) -> bool:
        return ctx.platform == HostPlatform.WIN32

    @property
    def name(self) -> str:
        return 'host_execution_policy'

    def run(self, ctx: DeploymentContext) -> StepResult:
        script = (
            '$p = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue; '
            'if ($p -ne "RemoteSigned") { '
            'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force }'
        )
        code = subprocess.call(
            ['powershell.exe', '-NoProfile', '-Command', script],
            cwd=str(ctx.project_root),
        )
        return StepResult(exit_code=code)


class GitSubmoduleUpdateStep(DeploymentStep):
    def __init__(self, paths: tuple[str, ...] = DEFAULT_CORE_SUBMODULES, branch: str = 'dev') -> None:
        self._paths = paths
        self._branch = branch

    @property
    def name(self) -> str:
        return 'git_submodule_update'

    def run(self, ctx: DeploymentContext) -> StepResult:
        root = ctx.project_root
        paths = ctx.options.get('submodule_paths', self._paths)
        branch = ctx.option_str('checkout_branch', self._branch)
        cmd = ['git', 'submodule', 'update', '--init', '--remote', *paths]
        code = subprocess.call(cmd, cwd=str(root))
        if code != 0:
            return StepResult(exit_code=code, message='Не удалось обновить git submodule')
        for rel in paths:
            sub = root / rel
            if sub.is_dir():
                subprocess.call(['git', 'checkout', branch], cwd=str(sub))
        print(format_console('ok', 'Git submodule обновлены'))
        return StepResult()


class ConfigScaffoldStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'config_scaffold'

    def run(self, ctx: DeploymentContext) -> StepResult:
        script = ctx.project_root / 'core' / 'deployment' / 'scripts' / 'scaffold_config_files.py'
        if not script.is_file():
            print(format_console('skip', 'Скрипт scaffold не найден'))
            return StepResult()
        argv = [*host_ops.system_python_argv(ctx.platform), str(script), '--root', str(ctx.project_root)]
        code = subprocess.call(argv, cwd=str(ctx.project_root))
        return StepResult(exit_code=code)


class CreateVenvStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'create_venv'

    def run(self, ctx: DeploymentContext) -> StepResult:
        code = host_ops.create_or_validate_venv(ctx, recreate=ctx.option_bool('recreate_venv'))
        return StepResult(exit_code=code)


class PoetryInstallStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'poetry_install'

    def run(self, ctx: DeploymentContext) -> StepResult:
        code = host_ops.install_poetry_in_venv(ctx)
        return StepResult(exit_code=code)


class HostCliInstallStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'cli_install'

    def run(self, ctx: DeploymentContext) -> StepResult:
        code = invoke_dispatch(ctx, 'cli', 'install')
        return StepResult(exit_code=code)


class UpdateModuleSubmodulesStep(DeploymentStep):
    @property
    def name(self) -> str:
        return 'update_module_submodules'

    def run(self, ctx: DeploymentContext) -> StepResult:
        gitmodules = ctx.project_root / '.gitmodules'
        if not gitmodules.is_file():
            return StepResult(exit_code=1, message='.gitmodules не найден')
        result = subprocess.run(
            ['git', 'config', '-f', '.gitmodules', '--get-regexp', r'^submodule\..*\.path$'],
            cwd=str(ctx.project_root),
            capture_output=True,
            text=True,
            check=False,
        )
        paths: list[str] = []
        for line in (result.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith('modules/'):
                paths.append(parts[1])
        if not paths:
            print(format_console('skip', 'Submodule модулей не найдены'))
            return StepResult()
        for rel in paths:
            subprocess.call(
                ['git', 'submodule', 'update', '--init', '--remote', '--', rel],
                cwd=str(ctx.project_root),
            )
            branch = 'dev'
            subprocess.call(['git', 'checkout', branch], cwd=str(ctx.project_root / rel))
        print(format_console('ok', f'Обновлено модулей: {len(paths)}'))
        return StepResult()
