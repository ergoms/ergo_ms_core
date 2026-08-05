"""Host subprocess: venv, api/npm, foreground scripts."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from project_layout import (  # noqa: E402
    nodejs_bin_dir,
    npm_exe,
    npm_node_modules_dir,
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
        print(format_console('error', t('venv_not_found_msg')), file=sys.stderr)
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
                t('npm_not_found'),
            ),
            file=sys.stderr,
        )
        return 1
    npm_root = npm_root_dir(ctx.project_root)
    pkg = npm_root / 'package.json'
    if not pkg.is_file():
        print(
            format_console('error', t('package_json_not_found_npm')),
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
    script_args: Sequence[str] = (),
) -> int:
    py_argv = pick_python_for_ctx(ctx, prefer_venv=prefer_venv)
    script = ctx.project_root / script_rel
    if not script.is_file():
        print(format_console('error', t('script_not_found', script_rel=script_rel)), file=sys.stderr)
        return 1
    env = api_env(ctx) if prefer_venv else os.environ.copy()
    return subprocess.call(
        [*py_argv, str(script), *script_args],
        cwd=str(cwd or ctx.project_root),
        env=env,
    )


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
        print(format_console('error', t('venv_not_found_msg')), file=sys.stderr)
        return 1
    env = api_env(ctx)
    code = subprocess.call([str(py), '-m', 'pip', 'install', '--upgrade', 'pip'], cwd=str(ctx.project_root), env=env)
    if code == 0:
        print(format_console('ok', t('pip_upgraded')))
    return code


def poetry_available_in_venv(ctx: DeploymentContext) -> bool:
    """True, если в project venv уже есть рабочий `poetry`."""
    py = venv_python_exe(ctx.project_root, ctx.platform)
    if not py.is_file():
        return False
    check = subprocess.run(
        [str(py), '-m', 'poetry', '--version'],
        cwd=str(ctx.project_root),
        env=api_env(ctx),
        capture_output=True,
        check=False,
    )
    if check.returncode == 0:
        return True
    poetry_exe = (
        venv_dir(ctx.project_root) / 'Scripts' / 'poetry.exe'
        if ctx.platform == HostPlatform.WIN32
        else venv_dir(ctx.project_root) / 'bin' / 'poetry'
    )
    if not poetry_exe.is_file():
        return False
    check = subprocess.run(
        [str(poetry_exe), '--version'],
        cwd=str(ctx.project_root),
        env=api_env(ctx),
        capture_output=True,
        check=False,
    )
    return check.returncode == 0


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
                    t('portable_python_not_found'),
                ),
                file=sys.stderr,
            )
            return 1
        base_argv = system_python_argv(platform)
        print(
            format_console(
                'info',
                t('venv_from_system_python'),
            )
        )

    needs_recreation = recreate or not py_exe.is_file()

    if not needs_recreation and py_exe.is_file():
        check = subprocess.run([str(py_exe), '--version'], capture_output=True, check=False)
        if check.returncode != 0:
            needs_recreation = True

    created_now = False
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
            print(format_console('error', t('venv_create_failed')), file=sys.stderr)
            return code
        print(format_console('ok', t('venv_created')))
        created_now = True
    else:
        print(format_console('info', t('venv_already_exists')))

    if not pip_exe.is_file():
        # ensurepip может отсутствовать в свежем venv — попробуем через python -m ensurepip
        ensure = subprocess.call([str(py_exe), '-m', 'ensurepip', '--upgrade'], cwd=str(root))
        if ensure != 0 or not pip_exe.is_file():
            print(format_console('error', t('pip_not_in_venv')), file=sys.stderr)
            return 1

    # Повторный setup: не гонять pip upgrade, если venv уже был валиден.
    if not created_now and not recreate and not ctx.option_bool('force'):
        print(format_console('skip', t('pip_upgrade_skip_existing')))
        return 0

    pip_code = upgrade_pip_in_venv(ctx)
    if pip_code != 0:
        return pip_code
    return 0


def install_poetry_in_venv(ctx: DeploymentContext) -> int:
    py = venv_python_exe(ctx.project_root, ctx.platform)
    if not py.is_file():
        print(format_console('error', t('venv_not_found_msg')), file=sys.stderr)
        return 1
    force = ctx.option_bool('force')
    if not force and poetry_available_in_venv(ctx):
        print(format_console('skip', t('poetry_already_installed_skip')))
        return 0
    if ctx.platform == HostPlatform.WIN32:
        pip = venv_dir(ctx.project_root) / 'Scripts' / 'pip.exe'
        cmd = [str(pip), 'install', 'poetry']
        if force:
            cmd = [str(pip), 'install', '--upgrade', '--force-reinstall', 'poetry']
    else:
        cmd = [str(py), '-m', 'pip', 'install', '--upgrade', 'poetry']
        if force:
            cmd = [str(py), '-m', 'pip', 'install', '--upgrade', '--force-reinstall', 'poetry']
    code = subprocess.call(cmd, cwd=str(ctx.project_root), env=api_env(ctx))
    if code == 0:
        print(format_console('ok', t('poetry_installed')))
    return code


HOST_NPM_DEPS_MARKER = Path('node_modules/.ergo-host-deps-ok')
CLIENT_BUILD_STAMP_REL = Path('virtual_env/cache/.ergo-client-build-ok')


def host_npm_deps_marker(project_root: Path) -> Path:
    return npm_root_dir(project_root) / HOST_NPM_DEPS_MARKER


def npm_deps_input_paths(project_root: Path) -> list[Path]:
    """Файлы, при изменении которых нужен повторный npm install:all."""
    npm_root = npm_root_dir(project_root)
    paths: list[Path] = [
        npm_root / 'package.json',
        npm_root / 'package-lock.json',
        project_root / 'core' / 'client' / 'package.json',
    ]
    modules = project_root / 'modules'
    if modules.is_dir():
        for pkg in sorted(modules.glob('*/client/package.json')):
            paths.append(pkg)
    return paths


def host_npm_deps_up_to_date(project_root: Path) -> bool:
    """Smart-skip для host npm (аналог DOCKER_NPM_INSTALL=smart)."""
    marker = host_npm_deps_marker(project_root)
    node_modules = npm_node_modules_dir(project_root)
    if not marker.is_file() or not node_modules.is_dir():
        return False
    try:
        next(node_modules.iterdir())
    except StopIteration:
        return False
    try:
        marker_mtime = marker.stat().st_mtime
    except OSError:
        return False
    for path in npm_deps_input_paths(project_root):
        if not path.is_file():
            continue
        try:
            if path.stat().st_mtime > marker_mtime:
                return False
        except OSError:
            return False
    return True


def touch_host_npm_deps_marker(project_root: Path) -> None:
    marker = host_npm_deps_marker(project_root)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text('ok\n', encoding='utf-8')


_CLIENT_BUILD_ENV_KEYS = (
    'CLIENT_API_HOST',
    'CLIENT_API_PORT',
    'CLIENT_USE_RELATIVE_API',
    'CLIENT_DEFAULT_LANGUAGE',
    'DEFAULT_LANGUAGE',
    'CLIENT_LOG_LEVEL',
    'CLIENT_BROWSER_LOG_ENABLED',
    'CLIENT_MONITORING_ENABLED',
    'CLIENT_MODULARITY',
    'CLIENT_MODULES',
    'CLIENT_MODULE_REMOTES',
    'CLIENT_FEDERATION_SHARED',
    'CLIENT_DEPLOY_TYPE',
    'CLIENT_STANDALONE_MODULE_CHUNKS',
    'DISABLED_MODULES',
    'ERGO_PROXY',
    'NGINX_ENABLED',
    'ERGO_ENV',
    'API_PORT',
    'API_PASSWORD_MIN_LENGTH',
    'API_PASSWORD_MAX_LENGTH',
    'API_PASSWORD_REQUIRE_LOWERCASE',
    'API_PASSWORD_REQUIRE_UPPERCASE',
    'API_PASSWORD_REQUIRE_DIGIT',
    'API_PASSWORD_REQUIRE_SPECIAL',
    'REALTIME_TRANSPORT',
    'REALTIME_POLL_PRESENCE_INTERVAL',
    'REALTIME_POLL_NOTIFICATIONS_INTERVAL',
    'REALTIME_POLL_ADMIN_PRESENCE_INTERVAL',
    'REALTIME_POLL_MESSENGER_INTERVAL',
    'MEDIA_UPLOAD_MAX_SIZE',
    'VERSION',
)


def client_dist_index(project_root: Path) -> Path:
    return project_root / 'core' / 'client' / 'dist' / 'index.html'


def client_build_stamp_path(project_root: Path) -> Path:
    return project_root / CLIENT_BUILD_STAMP_REL


def _git_head(repo_dir: Path) -> str:
    if not repo_dir.is_dir():
        return ''
    result = subprocess.run(
        ['git', 'rev-parse', 'HEAD'],
        cwd=str(repo_dir),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return ''
    return (result.stdout or '').strip()


def client_build_fingerprint(project_root: Path, raw_env: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for path in npm_deps_input_paths(project_root):
        if not path.is_file():
            continue
        digest.update(str(path.relative_to(project_root)).encode('utf-8'))
        digest.update(path.read_bytes())
    for key in _CLIENT_BUILD_ENV_KEYS:
        digest.update(f'{key}={raw_env.get(key, "")}\n'.encode('utf-8'))
    # Любые CLIENT_* из env сверх списка
    for key in sorted(k for k in raw_env if k.startswith('CLIENT_') and k not in _CLIENT_BUILD_ENV_KEYS):
        digest.update(f'{key}={raw_env.get(key, "")}\n'.encode('utf-8'))
    # Код клиента / модулей: commit submodule, иначе setup/deploy после pull не пропустит build
    digest.update(f'client_head={_git_head(project_root / "core" / "client")}\n'.encode('utf-8'))
    modules = project_root / 'modules'
    if modules.is_dir():
        for client_dir in sorted(modules.glob('*/client')):
            if not client_dir.is_dir():
                continue
            mod_root = client_dir.parent
            digest.update(
                f'module_client_head={mod_root.name}:{_git_head(mod_root)}\n'.encode('utf-8')
            )
    return digest.hexdigest()


def client_build_up_to_date(project_root: Path, raw_env: dict[str, str]) -> bool:
    if not client_dist_index(project_root).is_file():
        return False
    stamp = client_build_stamp_path(project_root)
    if not stamp.is_file():
        return False
    try:
        return stamp.read_text(encoding='utf-8').strip() == client_build_fingerprint(
            project_root, raw_env
        )
    except OSError:
        return False


def write_client_build_stamp(project_root: Path, raw_env: dict[str, str]) -> None:
    stamp = client_build_stamp_path(project_root)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(client_build_fingerprint(project_root, raw_env) + '\n', encoding='utf-8')
