"""Host subprocess: venv, api/npm, foreground scripts."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402
from project_layout import tool_cache_environ  # noqa: E402

from lifecycle.context import DeploymentContext, HostPlatform  # noqa: E402

VENV_REL = Path('virtual_env/python')


def venv_dir(project_root: Path) -> Path:
    return project_root / VENV_REL


def venv_python_exe(project_root: Path, platform: HostPlatform) -> Path:
    base = venv_dir(project_root)
    if platform == HostPlatform.WIN32:
        return base / 'Scripts' / 'python.exe'
    return base / 'bin' / 'python'


def venv_exists(project_root: Path, platform: HostPlatform) -> bool:
    py = venv_python_exe(project_root, platform)
    return py.is_file()


def system_python_argv(platform: HostPlatform) -> list[str]:
    if platform == HostPlatform.WIN32:
        if shutil.which('py'):
            return ['py', '-3.12']
        return ['python']
    for name in ('python3.12', 'python3', 'python'):
        if shutil.which(name):
            return [name]
    return ['python3']


def pick_python_for_ctx(ctx: DeploymentContext, *, prefer_venv: bool = True) -> list[str]:
    if prefer_venv and venv_exists(ctx.project_root, ctx.platform):
        return [str(venv_python_exe(ctx.project_root, ctx.platform))]
    return system_python_argv(ctx.platform)


def api_env(ctx: DeploymentContext) -> dict[str, str]:
    env = os.environ.copy()
    root = ctx.project_root
    venv = venv_dir(root)
    env['PYTHONPATH'] = str(root)
    env['PYTHONIOENCODING'] = 'utf-8'
    env['PYTHONUNBUFFERED'] = '1'
    env['POETRY_VIRTUALENVS_CREATE'] = 'false'
    env.update(tool_cache_environ(root))
    if venv_exists(root, ctx.platform):
        env['VIRTUAL_ENV'] = str(venv)
        if ctx.platform == HostPlatform.WIN32:
            scripts = venv / 'Scripts'
            env['PATH'] = f'{scripts};{env.get("PATH", "")}'
        else:
            bindir = venv / 'bin'
            env['PATH'] = f'{bindir}:{env.get("PATH", "")}'
    return env


def api_cwd(ctx: DeploymentContext) -> Path:
    return ctx.project_root / 'core' / 'api'


def run_api_command(ctx: DeploymentContext, *args: str) -> int:
    if not venv_exists(ctx.project_root, ctx.platform):
        print(format_console('error', 'Виртуальное окружение не найдено'), file=sys.stderr)
        return 1
    py = venv_python_exe(ctx.project_root, ctx.platform)
    cmd = [str(py), '-m', 'commands', *args]
    return subprocess.call(cmd, cwd=str(api_cwd(ctx)), env=api_env(ctx))


def find_npm(platform: HostPlatform) -> str | None:
    if platform == HostPlatform.WIN32:
        for name in ('npm.cmd', 'npm'):
            path = shutil.which(name)
            if path:
                return path
        return None
    return shutil.which('npm')


def run_npm(ctx: DeploymentContext, script: str, extra_args: Sequence[str] = ()) -> int:
    npm = find_npm(ctx.platform)
    if not npm:
        print(format_console('error', 'npm не найден в PATH'), file=sys.stderr)
        return 1
    pkg = ctx.project_root / 'package.json'
    if not pkg.is_file():
        print(format_console('error', 'package.json не найден в корне проекта'), file=sys.stderr)
        return 1
    cmd = [npm, 'run', script, *extra_args]
    env = os.environ.copy()
    env.update(tool_cache_environ(ctx.project_root))
    return subprocess.call(cmd, cwd=str(ctx.project_root), env=env)


def run_python_script(
    ctx: DeploymentContext,
    script_rel: str,
    *,
    prefer_venv: bool = True,
    cwd: Path | None = None,
) -> int:
    py_argv = pick_python_for_ctx(ctx, prefer_venv=prefer_venv)
    script = ctx.project_root / script_rel
    if not script.is_file():
        print(format_console('error', f'Скрипт не найден: {script_rel}'), file=sys.stderr)
        return 1
    env = api_env(ctx) if prefer_venv else os.environ.copy()
    return subprocess.call([*py_argv, str(script)], cwd=str(cwd or ctx.project_root), env=env)


def create_or_validate_venv(ctx: DeploymentContext, *, recreate: bool = False) -> int:
    root = ctx.project_root
    platform = ctx.platform
    vpath = venv_dir(root)
    py_exe = venv_python_exe(root, platform)
    pip_exe = (
        vpath / 'Scripts' / 'pip.exe'
        if platform == HostPlatform.WIN32
        else vpath / 'bin' / 'pip'
    )

    needs_recreation = recreate or not py_exe.is_file()

    if not needs_recreation and py_exe.is_file():
        check = subprocess.run([str(py_exe), '--version'], capture_output=True, check=False)
        if check.returncode != 0:
            needs_recreation = True

    if needs_recreation:
        if vpath.exists():
            contents = list(vpath.iterdir()) if vpath.is_dir() else []
            only_gitkeep = len(contents) == 1 and contents[0].name == '.gitkeep'
            if contents and not only_gitkeep:
                shutil.rmtree(vpath, ignore_errors=True)
            elif not vpath.exists():
                vpath.mkdir(parents=True, exist_ok=True)
        else:
            vpath.mkdir(parents=True, exist_ok=True)

        argv = [*system_python_argv(platform), '-m', 'venv', str(vpath)]
        code = subprocess.call(argv, cwd=str(root))
        if code != 0:
            print(format_console('error', 'Не удалось создать виртуальное окружение'), file=sys.stderr)
            return code
        print(format_console('ok', 'Виртуальное окружение создано'))
    else:
        print(format_console('info', 'Виртуальное окружение уже существует'))

    if not pip_exe.is_file():
        print(format_console('error', 'pip не найден в виртуальном окружении'), file=sys.stderr)
        return 1
    return 0


def install_poetry_in_venv(ctx: DeploymentContext) -> int:
    py = venv_python_exe(ctx.project_root, ctx.platform)
    if not py.is_file():
        print(format_console('error', 'Виртуальное окружение не найдено'), file=sys.stderr)
        return 1
    if ctx.platform == HostPlatform.WIN32:
        pip = venv_dir(ctx.project_root) / 'Scripts' / 'pip.exe'
        cmd = [str(pip), 'install', 'poetry']
    else:
        cmd = [str(py), '-m', 'pip', 'install', '--upgrade', '--force-reinstall', 'poetry']
    code = subprocess.call(cmd, cwd=str(ctx.project_root))
    if code == 0:
        print(format_console('ok', 'Poetry установлен'))
    return code
