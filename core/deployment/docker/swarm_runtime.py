"""Реестр образов и стек Swarm для воркеров Celery."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from cli_locale import t
from console_tags import format_console
from env_file_loader import load_project_env, parse_env_file
from project_layout import cache_dir, ensure_dir

from generate_swarm_stack import OUTPUT, render_stack

STACK_NAME = 'ergo_workers'
REGISTRY_NAME = 'ergo-registry'
IMAGE_NAME = 'ergo-worker:local'


def _root() -> Path:
    return Path(__file__).resolve().parents[3]


def _env(root: Path) -> dict[str, str]:
    return load_project_env(root)


def _registry(env: dict[str, str]) -> str:
    return str(env.get('DOCKER_SWARM_REGISTRY') or '').strip()


def _manager_host(env: dict[str, str], registry: str) -> str:
    host = str(env.get('DOCKER_SWARM_MANAGER_HOST') or '').strip()
    if host:
        return host
    if ':' in registry:
        return registry.rsplit(':', 1)[0]
    return registry


def _gpu_enabled(env: dict[str, str]) -> bool:
    raw = str(env.get('DOCKER_SWARM_GPU') or 'true').strip().lower()
    return raw not in {'0', 'false', 'no', 'off'}


def _docker() -> list[str] | None:
    """docker из PATH. Если сокет недоступен, а sudo без пароля есть — через него."""
    cached = getattr(_docker, '_argv', None)
    if cached is not None:
        return cached or None
    binary = shutil.which('docker')
    if not binary:
        _docker._argv = []  # type: ignore[attr-defined]
        return None
    direct = subprocess.run([binary, 'info'], capture_output=True, text=True, check=False)
    if direct.returncode == 0:
        argv = [binary]
    else:
        sudo = shutil.which('sudo')
        elevated = (
            subprocess.run(
                [sudo, '-n', binary, 'info'],
                capture_output=True,
                text=True,
                check=False,
            )
            if sudo
            else None
        )
        argv = [sudo, '-n', binary] if elevated is not None and elevated.returncode == 0 else [binary]
    _docker._argv = argv  # type: ignore[attr-defined]
    return argv


def _run(cmd: list[str]) -> int:
    result = subprocess.run(cmd, check=False)
    return int(result.returncode)


def _quote_env(value: str) -> str:
    text = str(value).replace('\r', '').replace('\n', '')
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def prepare_worker_files(root: Path, manager_host: str) -> tuple[Path, Path]:
    """Копии .env и databases.yaml в кэше. Swarm раздаёт их воркерам как config."""
    import yaml

    folder = ensure_dir(cache_dir(root) / 'swarm-config')
    merged = load_project_env(root)
    modules = root / 'modules'
    if modules.is_dir():
        for path in sorted(modules.glob('*/.env')):
            merged.update(parse_env_file(path))
    dotenv = folder / 'dotenv'
    lines = [f'{key}={_quote_env(value)}' for key, value in sorted(merged.items())]
    dotenv.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    databases_src = root / 'databases.yaml'
    databases = folder / 'databases.yaml'
    if databases_src.is_file():
        raw = databases_src.read_text(encoding='utf-8')
        try:
            parsed = yaml.safe_load(raw) or {}
        except Exception:  # noqa: BLE001
            parsed = {}
        if isinstance(parsed, dict):
            for section in parsed.values():
                if not isinstance(section, dict):
                    continue
                host = str(section.get('host') or '').strip()
                if host in {'127.0.0.1', 'localhost'}:
                    section['host'] = manager_host
            databases.write_text(
                yaml.safe_dump(parsed, allow_unicode=True, sort_keys=False),
                encoding='utf-8',
            )
        else:
            shutil.copyfile(databases_src, databases)
    else:
        databases.write_text('{}\n', encoding='utf-8')
    return dotenv, databases


def write_stack(root: Path) -> Path:
    env = _env(root)
    registry = _registry(env)
    if not registry:
        raise SystemExit(format_console('error', t('docker_swarm_registry_missing')))
    dotenv, databases = prepare_worker_files(root, _manager_host(env, registry))
    content = render_stack(
        image=f'{registry}/{IMAGE_NAME}',
        manager_host=_manager_host(env, registry),
        databases_file=str(databases),
        env_file=str(dotenv),
        gpu=_gpu_enabled(env),
        media_url=str(env.get('DOCKER_SWARM_MEDIA_URL') or '').strip(),
        ollama_url=str(env.get('DOCKER_SWARM_OLLAMA_URL') or '').strip(),
    )
    OUTPUT.write_text(content, encoding='utf-8')
    print(format_console('ok', t('docker_swarm_stack_written', output=OUTPUT)))
    return OUTPUT


def cmd_registry() -> int:
    root = _root()
    env = _env(root)
    registry = _registry(env)
    if not registry:
        print(format_console('error', t('docker_swarm_registry_missing')), file=sys.stderr)
        return 1
    docker = _docker()
    if not docker:
        print(format_console('error', t('docker_not_found_short')), file=sys.stderr)
        return 1
    host = _manager_host(env, registry)
    port = registry.rsplit(':', 1)[-1] if ':' in registry else '5000'
    data = ensure_dir(cache_dir(root) / 'docker-registry')
    _run([*docker, 'rm', '-f', REGISTRY_NAME])
    code = _run([
        docker, 'run', '-d',
        '--name', REGISTRY_NAME,
        '--restart', 'unless-stopped',
        '-p', f'{host}:{port}:5000',
        '-v', f'{data}:/var/lib/registry',
        'registry:2',
    ])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_registry_started', registry=registry)))
    print(format_console('info', t('docker_swarm_insecure_hint', registry=registry)))
    return 0


def cmd_push() -> int:
    root = _root()
    env = _env(root)
    registry = _registry(env)
    if not registry:
        print(format_console('error', t('docker_swarm_registry_missing')), file=sys.stderr)
        return 1
    docker = _docker()
    if not docker:
        print(format_console('error', t('docker_not_found_short')), file=sys.stderr)
        return 1
    image = f'{registry}/{IMAGE_NAME}'
    dockerfile = Path(__file__).resolve().parent / 'Dockerfile.python'
    code = _run([
        *docker, 'build',
        '-f', str(dockerfile),
        '--target', 'worker',
        '-t', image,
        str(root),
    ])
    if code != 0:
        return code
    code = _run([*docker, 'push', image])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_pushed', image=image)))
    return 0


def _label_workers(docker: str) -> None:
    result = subprocess.run(
        [*docker, 'node', 'ls', '--format', '{{.Hostname}} {{.ManagerStatus}}'],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return
    for line in result.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        hostname = parts[0]
        status = parts[1] if len(parts) > 1 else ''
        if status in {'Leader', 'Reachable'}:
            continue
        subprocess.run(
            [*docker, 'node', 'update', '--label-add', 'ergo.worker=true', hostname],
            check=False,
        )


def cmd_deploy() -> int:
    root = _root()
    docker = _docker()
    if not docker:
        print(format_console('error', t('docker_not_found_short')), file=sys.stderr)
        return 1
    stack = write_stack(root)
    _label_workers(docker)
    code = _run([*docker, 'stack', 'deploy', '-c', str(stack), STACK_NAME])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_deployed', stack=STACK_NAME)))
    if _gpu_enabled(_env(root)):
        print(format_console('info', t('docker_swarm_gpu_hint')))
    return 0


def cmd_down() -> int:
    docker = _docker()
    if not docker:
        print(format_console('error', t('docker_not_found_short')), file=sys.stderr)
        return 1
    code = _run([*docker, 'stack', 'rm', STACK_NAME])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_removed', stack=STACK_NAME)))
    return 0


def _python(root: Path) -> Path | None:
    if sys.platform == 'win32':
        path = root / 'virtual_env' / 'python' / 'Scripts' / 'python.exe'
    else:
        path = root / 'virtual_env' / 'python' / 'bin' / 'python'
    return path if path.is_file() else None


def _watch_pid_path(root: Path) -> Path:
    return cache_dir(root) / 'celery_balance' / 'watch.pid'


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _watch_cmdline(pid: int) -> str:
    proc = Path(f'/proc/{pid}/cmdline')
    if not proc.is_file():
        return ''
    try:
        return proc.read_bytes().replace(b'\x00', b' ').decode('utf-8', errors='replace')
    except OSError:
        return ''


def _stop_watch(root: Path) -> None:
    path = _watch_pid_path(root)
    if not path.is_file():
        return
    try:
        pid = int(path.read_text(encoding='utf-8').strip() or '0')
    except ValueError:
        path.unlink(missing_ok=True)
        return
    cmdline = _watch_cmdline(pid)
    if cmdline and 'celery_balance' not in cmdline:
        path.unlink(missing_ok=True)
        return
    if _pid_alive(pid):
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while _pid_alive(pid) and time.monotonic() < deadline:
            time.sleep(0.2)
        if _pid_alive(pid):
            os.kill(pid, signal.SIGKILL)
        print(format_console('ok', t('celery_cluster_watch_stopped')))
    path.unlink(missing_ok=True)


def _ensure_watch(root: Path) -> None:
    python = _python(root)
    script = root / 'core' / 'deployment' / 'celery_balance' / 'cli.py'
    if python is None or not script.is_file():
        return
    _stop_watch(root)
    folder = ensure_dir(cache_dir(root) / 'celery_balance')
    logs = ensure_dir(root / 'logs')
    handle = (logs / 'celery-balance-watch.log').open('a', encoding='utf-8')
    proc = subprocess.Popen(
        [str(python), str(script), '--watch'],
        cwd=str(root),
        stdout=handle,
        stderr=handle,
        start_new_session=True,
    )
    handle.close()
    (folder / 'watch.pid').write_text(str(proc.pid), encoding='utf-8')
    print(format_console('ok', t('celery_cluster_watch_started')))


def _mark_agent_ready(root: Path, ready: bool) -> None:
    path = ensure_dir(cache_dir(root) / 'celery_balance') / 'agent_ready'
    if ready:
        path.write_text('1\n', encoding='utf-8')
        return
    path.unlink(missing_ok=True)


def _swarm_active(docker: list[str]) -> bool:
    result = subprocess.run(
        [*docker, 'info', '--format', '{{.Swarm.LocalNodeState}}'],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip().lower() == 'active'


def _image_has_prepare(docker: list[str], image: str) -> bool:
    probe = subprocess.run(
        [*docker, 'image', 'inspect', '--format', '{{.Id}}', image],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        return False
    check = subprocess.run(
        [
            *docker, 'run', '--rm', '--entrypoint', 'test', image,
            '-f', '/app/core/deployment/scripts/prepare_swarm_packages.py',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return check.returncode == 0


def _wait_for_agent(root: Path, timeout: float = 45) -> bool:
    from celery_balance.cluster import connect, list_views

    client = connect(root)
    if client is None:
        return False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(not view.primary for view in list_views(client)):
            return True
        time.sleep(2)
    return False


def _run_balance_once(root: Path) -> None:
    python = _python(root)
    script = root / 'core' / 'deployment' / 'celery_balance' / 'cli.py'
    if python is None or not script.is_file():
        return
    subprocess.run([str(python), str(script)], cwd=str(root), check=False)


def sync_on_start() -> int:
    """Поднять наблюдатель плана и стек. Нет кластера или Swarm — обычный локальный старт."""
    from celery_balance.settings import load_settings

    root = _root()
    if not load_settings(root).cluster_enabled:
        return 0
    env = _env(root)
    registry = _registry(env)
    docker = _docker()
    swarm_up = bool(registry and docker and _swarm_active(docker))
    image = f'{registry}/{IMAGE_NAME}' if registry else ''
    image_ready = bool(swarm_up and image and _image_has_prepare(docker, image))
    deployed = swarm_up and image_ready and cmd_deploy() == 0
    if not deployed:
        _mark_agent_ready(root, False)
        _ensure_watch(root)
        if swarm_up and not image_ready:
            print(format_console('warn', t('celery_cluster_image_missing', image=image)))
        elif registry and not swarm_up:
            print(format_console('warn', t('celery_cluster_swarm_skipped')))
        elif swarm_up and image_ready:
            print(format_console('warn', t('celery_cluster_swarm_skipped')))
        return 0
    _mark_agent_ready(root, True)
    _ensure_watch(root)
    if _wait_for_agent(root):
        _run_balance_once(root)
    return 0


def sync_on_stop() -> int:
    """Снять стек, пока Redis ещё жив. Нет Swarm — ничего не ломаем."""
    root = _root()
    _stop_watch(root)
    docker = _docker()
    if not docker or not _swarm_active(docker):
        return 0
    listed = subprocess.run(
        [*docker, 'stack', 'ls', '--format', '{{.Name}}'],
        capture_output=True,
        text=True,
        check=False,
    )
    names = {line.strip() for line in listed.stdout.splitlines()}
    if STACK_NAME not in names:
        return 0
    cmd_down()
    return 0
