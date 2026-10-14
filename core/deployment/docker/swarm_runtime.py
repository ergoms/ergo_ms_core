"""Реестр образов и стек Swarm для воркеров Celery."""

from __future__ import annotations

import shutil
import subprocess
import sys
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


def _docker() -> str | None:
    return shutil.which('docker')


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
    _run([docker, 'rm', '-f', REGISTRY_NAME])
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
        docker, 'build',
        '-f', str(dockerfile),
        '--target', 'worker',
        '-t', image,
        str(root),
    ])
    if code != 0:
        return code
    code = _run([docker, 'push', image])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_pushed', image=image)))
    return 0


def _label_workers(docker: str) -> None:
    result = subprocess.run(
        [docker, 'node', 'ls', '--format', '{{.Hostname}} {{.ManagerStatus}}'],
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
            [docker, 'node', 'update', '--label-add', 'ergo.worker=true', hostname],
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
    code = _run([docker, 'stack', 'deploy', '-c', str(stack), STACK_NAME])
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
    code = _run([docker, 'stack', 'rm', STACK_NAME])
    if code != 0:
        return code
    print(format_console('ok', t('docker_swarm_removed', stack=STACK_NAME)))
    return 0
