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
from project_layout import (  # noqa: E402
    nodejs_bin_dir,
    npm_exe,
    npm_root_dir,
    portable_python_exe,
    tool_cache_environ,
)

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


def portable_python_available(project_root: Path) -> bool:
    exe = portable_python_exe(project_root)
    return exe.is_file()


def _env_flag(ctx: DeploymentContext, name: str, default: str = 'true') -> bool:
    raw = ctx.raw_env.get(name, default)
    if raw is None or str(raw).strip() == '':
        raw = default
    return str(raw).strip().lower() in ('1', 'true', 'yes', 'on')


def portable_python_enabled(ctx: DeploymentContext) -> bool:
    return _env_flag(ctx, 'PORTABLE_PYTHON_ENABLED', 'true')


def portable_nodejs_enabled(ctx: DeploymentContext) -> bool:
    return _env_flag(ctx, 'PORTABLE_NODEJS_ENABLED', 'true')


def system_python_argv(platform: HostPlatform) -> list[str]:
    if platform == HostPlatform.WIN32:
        if shutil.which('py'):
            return ['py', '-3.12']
        return ['python']
    for name in ('python3.12', 'python3', 'python'):
        if shutil.which(name):
            return [name]
    return ['python3']


def base_python_argv(project_root: Path, platform: HostPlatform) -> list[str]:
    """Portable CPython → системный Python (для scaffold / bootstrap)."""
    portable = portable_python_exe(project_root)
    if portable.is_file():
        return [str(portable)]
    return system_python_argv(platform)


def pick_python_for_ctx(ctx: DeploymentContext, *, prefer_venv: bool = True) -> list[str]:
    if prefer_venv and venv_exists(ctx.project_root, ctx.platform):
        return [str(venv_python_exe(ctx.project_root, ctx.platform))]
    return base_python_argv(ctx.project_root, ctx.platform)


def _prepend_path(env: dict[str, str], *dirs: Path) -> None:
    existing = env.get('PATH', '')
    parts = [str(d) for d in dirs if d.is_dir()]
    if not parts:
        return
    sep = ';' if sys.platform == 'win32' else ':'
    env['PATH'] = sep.join([*parts, existing]) if existing else sep.join(parts)


def api_env(ctx: DeploymentContext) -> dict[str, str]:
    env = os.environ.copy()
    root = ctx.project_root
    venv = venv_dir(root)
    env['PYTHONPATH'] = str(root)
    env['PYTHONIOENCODING'] = 'utf-8'
    env['PYTHONUNBUFFERED'] = '1'
    env['POETRY_VIRTUALENVS_CREATE'] = 'false'
    env.update(tool_cache_environ(root))
    path_dirs: list[Path] = []
    if venv_exists(root, ctx.platform):
        env['VIRTUAL_ENV'] = str(venv)
        if ctx.platform == HostPlatform.WIN32:
            path_dirs.append(venv / 'Scripts')
        else:
            path_dirs.append(venv / 'bin')
    path_dirs.append(nodejs_bin_dir(root))
    _prepend_path(env, *path_dirs)
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


def find_npm(project_root: Path, platform: HostPlatform) -> str | None:
    portable = npm_exe(project_root)
    if portable.is_file():
        return str(portable)
    if platform == HostPlatform.WIN32:
        for name in ('npm.cmd', 'npm'):
            path = shutil.which(name)
            if path:
                return path
        return None
    return shutil.which('npm')


def run_npm(ctx: DeploymentContext, script: str, extra_args: Sequence[str] = ()) -> int:
    npm = find_npm(ctx.project_root, ctx.platform)
    if not npm:
        print(
            format_console(
                'error',
                'npm не найден. Выполните ergoms install-nodejs или ergoms setup',
            ),
            file=sys.stderr,
        )
        return 1
    npm_root = npm_root_dir(ctx.project_root)
    pkg = npm_root / 'package.json'
    if not pkg.is_file():
        print(
            format_console('error', 'package.json не найден в virtual_env/npm'),
            file=sys.stderr,
        )
        return 1
    cmd = [npm, 'run', script, *extra_args]
    env = os.environ.copy()
    env.update(tool_cache_environ(ctx.project_root))
    _prepend_path(env, nodejs_bin_dir(ctx.project_root))
    return subprocess.call(cmd, cwd=str(npm_root), env=env)


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


def ensure_portable_python(ctx: DeploymentContext, *, force: bool = False) -> int:
    return invoke_runtime_install(ctx, 'python', force=force)


def ensure_portable_nodejs(ctx: DeploymentContext, *, force: bool = False) -> int:
    return invoke_runtime_install(ctx, 'nodejs', force=force)


def invoke_runtime_install(ctx: DeploymentContext, kind: str, *, force: bool = False) -> int:
    from lifecycle.host.shell_bridge import invoke_dispatch

    extra: list[str] = []
    if force:
        extra.append('--force')
    return invoke_dispatch(ctx, 'runtime', f'install-{kind}', *extra)


def upgrade_pip_in_venv(ctx: DeploymentContext) -> int:
    py = venv_python_exe(ctx.project_root, ctx.platform)
    if not py.is_file():
        print(format_console('error', 'Виртуальное окружение не найдено'), file=sys.stderr)
        return 1
    env = api_env(ctx)
    code = subprocess.call([str(py), '-m', 'pip', 'install', '--upgrade', 'pip'], cwd=str(ctx.project_root), env=env)
    if code == 0:
        print(format_console('ok', 'pip обновлён до крайней версии'))
    return code


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

    portable = portable_python_exe(root)
    if portable.is_file():
        base_argv = [str(portable)]
    else:
        if portable_python_enabled(ctx):
            print(
                format_console(
                    'error',
                    'Portable Python не найден. Выполните ergoms install-python или ergoms setup',
                ),
                file=sys.stderr,
            )
            return 1
        base_argv = system_python_argv(platform)
        print(
            format_console(
                'info',
                'PORTABLE_PYTHON_ENABLED=false — venv создаётся из системного Python',
            )
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

        argv = [*base_argv, '-m', 'venv', str(vpath)]
        code = subprocess.call(argv, cwd=str(root))
        if code != 0:
            print(format_console('error', 'Не удалось создать виртуальное окружение'), file=sys.stderr)
            return code
        print(format_console('ok', 'Виртуальное окружение создано'))
    else:
        print(format_console('info', 'Виртуальное окружение уже существует'))

    if not pip_exe.is_file():
        # ensurepip может отсутствовать в свежем venv — попробуем через python -m ensurepip
        ensure = subprocess.call([str(py_exe), '-m', 'ensurepip', '--upgrade'], cwd=str(root))
        if ensure != 0 or not pip_exe.is_file():
            print(format_console('error', 'pip не найден в виртуальном окружении'), file=sys.stderr)
            return 1

    pip_code = upgrade_pip_in_venv(ctx)
    if pip_code != 0:
        return pip_code
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
    code = subprocess.call(cmd, cwd=str(ctx.project_root), env=api_env(ctx))
    if code == 0:
        print(format_console('ok', 'Poetry установлен'))
    return code
