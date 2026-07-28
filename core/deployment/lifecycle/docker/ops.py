"""Docker Compose операции (вынесено из docker_cli для lifecycle и CLI)."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

DOCKER_DIR = Path(__file__).resolve().parent.parent.parent / 'docker'
DEPLOYMENT_DIR = DOCKER_DIR.parent
PROJECT_ROOT = DEPLOYMENT_DIR.parent.parent

if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))
if str(DOCKER_DIR) not in sys.path:
    sys.path.insert(0, str(DOCKER_DIR))

from console_tags import format_console  # noqa: E402
from env_resolvers import load_merged_env  # noqa: E402

from docker_runtime import (  # noqa: E402
    BUILD_CACHE_OUTPUT,
    compose_profiles,
    docker_mode,
    effective_docker_build_policy,
    postgres_container_env,
    prepare_compose_artifacts,
)

SETUP_MARKER_REL = Path('logs/.ergo-docker-setup-ok')
DOCKER_PYTHON_INSTALL_LOG = 'logs/docker/python-install.log'
DOCKER_NPM_INSTALL_LOG = 'logs/docker/npm-install.log'

from lifecycle.docker.ignore import DOCKERIGNORE_ARTIFACT_PATHS  # noqa: E402

COMPOSE_ARTIFACT_PATHS = (
    DOCKER_DIR / '.compose.env',
    DOCKER_DIR / '.compose.databases.yaml',
    DOCKER_DIR / 'docker-compose.workers.generated.yml',
    DOCKER_DIR / 'docker-compose.build.generated.yml',
    DOCKER_DIR / 'init' / 'postgres' / '02-celery-databases.sql',
    DOCKER_DIR / 'nginx' / 'ergo_ms.conf.rendered',
    *DOCKERIGNORE_ARTIFACT_PATHS,
)


def _truthy(raw: dict[str, str], name: str, default: bool = False) -> bool:
    value = raw.get(name, '')
    if value is None or str(value).strip() == '':
        return default
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')


def find_docker_compose() -> list[str]:
    if shutil.which('docker'):
        result = subprocess.run(
            ['docker', 'compose', 'version'],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return ['docker', 'compose']
    return []


def compose_file_list(mode: str, raw_env: dict[str, str]) -> list[Path]:
    files = [
        DOCKER_DIR / 'docker-compose.yml',
        DOCKER_DIR / f'docker-compose.{mode}.yml',
    ]
    if BUILD_CACHE_OUTPUT.is_file():
        files.append(BUILD_CACHE_OUTPUT)
    if _env_db_container(raw_env):
        files.append(DOCKER_DIR / 'docker-compose.postgres.yml')
    if _truthy(raw_env, 'DOCKER_PROFILE_NGINX'):
        files.append(DOCKER_DIR / 'docker-compose.nginx.yml')
    if _truthy(raw_env, 'DOCKER_PROFILE_JUPYTER'):
        files.append(DOCKER_DIR / 'docker-compose.jupyter.yml')
    workers = DOCKER_DIR / 'docker-compose.workers.generated.yml'
    if workers.is_file():
        files.append(workers)
    return files


def compose_file_list_full() -> list[Path]:
    files = [
        DOCKER_DIR / 'docker-compose.yml',
        DOCKER_DIR / 'docker-compose.dev.yml',
        DOCKER_DIR / 'docker-compose.prod.yml',
        DOCKER_DIR / 'docker-compose.postgres.yml',
        DOCKER_DIR / 'docker-compose.nginx.yml',
        DOCKER_DIR / 'docker-compose.jupyter.yml',
    ]
    if BUILD_CACHE_OUTPUT.is_file():
        files.append(BUILD_CACHE_OUTPUT)
    workers = DOCKER_DIR / 'docker-compose.workers.generated.yml'
    if workers.is_file():
        files.append(workers)
    return files


def _docker_image_exists(image_ref: str) -> bool:
    if not shutil.which('docker'):
        return False
    result = subprocess.run(
        ['docker', 'image', 'inspect', image_ref],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def _required_local_images(raw_env: dict[str, str]) -> list[str]:
    images = [
        raw_env.get('DOCKER_PYTHON_IMAGE', 'ergo_ms-python:local').strip() or 'ergo_ms-python:local',
        raw_env.get('DOCKER_NODE_IMAGE', 'ergo_ms-client:local').strip() or 'ergo_ms-client:local',
    ]
    return images


def should_skip_build(raw_env: dict[str, str]) -> bool:
    if effective_docker_build_policy(raw_env) != 'if-missing':
        return False
    return all(_docker_image_exists(name) for name in _required_local_images(raw_env))


def build_subprocess_env(raw_env: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    env['DOCKER_BUILDKIT'] = '1'
    env['COMPOSE_DOCKER_CLI_BUILD'] = '1'
    return env


def _env_db_container(raw_env: dict[str, str]) -> bool:
    mode = raw_env.get('DOCKER_DATABASE', 'container').strip().lower()
    if mode != 'container':
        return False
    return _truthy(raw_env, 'DOCKER_PROFILE_POSTGRES', default=True)


def bootstrap_service_names(raw_env: dict[str, str]) -> list[str]:
    services = ['redis']
    if _env_db_container(raw_env):
        services.append('postgres')
    return services


def render_nginx_docker_config(raw_env: dict[str, str]) -> Path:
    template = DOCKER_DIR / 'nginx' / 'ergo_ms.docker.conf.template'
    output = DOCKER_DIR / 'nginx' / 'ergo_ms.conf.rendered'
    content = template.read_text(encoding='utf-8')
    replacements = {
        '${ERGO_DOCKER_SERVICE_API}': raw_env.get('DOCKER_SERVICE_API', 'api'),
        '${ERGO_DOCKER_SERVICE_MEDIA}': raw_env.get('DOCKER_SERVICE_MEDIA', 'media-api'),
        '${API_PORT}': raw_env.get('API_PORT', '8000'),
        '${MEDIA_API_BIND_PORT}': raw_env.get('MEDIA_API_BIND_PORT', '8003'),
        '${NGINX_LISTEN_PORT}': raw_env.get('NGINX_LISTEN_PORT', '80'),
        '${NGINX_SERVER_NAME}': raw_env.get('NGINX_SERVER_NAME', 'localhost'),
        '${API_JUPYTER_BIND_PORT}': raw_env.get('API_JUPYTER_BIND_PORT', '8002'),
    }
    for key, value in replacements.items():
        content = content.replace(key, value)
    output.write_text(content, encoding='utf-8')
    return output


def warn_conflicts(raw_env: dict[str, str]) -> None:
    from ergo_modes import effective_docker_enabled, effective_nginx_enabled, effective_redis_enabled

    if not effective_docker_enabled(raw_env) and not _truthy(raw_env, 'DOCKER_ENABLED'):
        return
    if effective_redis_enabled(raw_env) and raw_env.get('REDIS_HOST', '127.0.0.1') not in (
        'redis',
        '127.0.0.1',
        'localhost',
        '',
    ):
        print(format_console(
            'warning',
            'REDIS_HOST / redis.host указывает на внешний хост — в Docker host remapped на сервис redis',
        ))
    if effective_nginx_enabled(raw_env) and not _truthy(raw_env, 'DOCKER_PROFILE_NGINX'):
        print(
            format_console(
                'warning',
                'ERGO_PROXY=nginx, но DOCKER_PROFILE_NGINX=false — nginx на хосте и в Docker могут конфликтовать',
            )
        )


def run_generate_workers(*, quiet: bool = False) -> int:
    script = DOCKER_DIR / 'generate_workers_compose.py'
    cmd = [sys.executable, str(script)]
    if quiet:
        cmd.append('--quiet')
    return subprocess.call(cmd, cwd=str(DOCKER_DIR))


def build_compose_cmd(
    action: str,
    *,
    mode: str | None = None,
    extra_args: list[str] | None = None,
    for_clean: bool = False,
    project_root: Path | None = None,
) -> tuple[list[str], Path]:
    compose_bin = find_docker_compose()
    if not compose_bin:
        print(format_console('error', 'Docker не найден. Установите Docker Desktop или docker compose CLI.'), file=sys.stderr)
        sys.exit(1)

    root = (project_root or PROJECT_ROOT).resolve()
    raw = load_merged_env(root)
    if mode:
        raw = dict(raw)
        raw['DOCKER_MODE'] = mode

    prepare_compose_artifacts(root)
    workers_file = DOCKER_DIR / 'docker-compose.workers.generated.yml'
    if for_clean:
        if not workers_file.is_file():
            print(format_console('info', 'Подготовка списка Celery worker-сервисов для остановки контейнеров…'))
            run_generate_workers(quiet=True)
    elif not workers_file.is_file():
        run_generate_workers()

    if for_clean or _truthy(raw, 'DOCKER_PROFILE_NGINX'):
        render_nginx_docker_config(raw)

    if not for_clean:
        warn_conflicts(raw)

    cmd = [*compose_bin]
    compose_files = compose_file_list_full() if for_clean else compose_file_list(docker_mode(raw), raw)
    for compose_file in compose_files:
        cmd.extend(['-f', str(compose_file)])

    profiles = ['postgres', 'nginx', 'jupyter'] if for_clean else compose_profiles(raw)
    for profile in profiles:
        cmd.extend(['--profile', profile])

    cmd.extend(['--env-file', str(DOCKER_DIR / '.compose.env')])
    cmd.append(action)
    if extra_args:
        cmd.extend(extra_args)
    return cmd, DOCKER_DIR


def run_api_oneoff(shell: str, *, mode: str | None = None) -> int:
    cmd, cwd = build_compose_cmd(
        'run',
        mode=mode,
        extra_args=[
            '--rm',
            '--no-deps',
            '-T',
            '-e',
            'ERGO_DOCKER_SERVICE_NAME=',
            '-e',
            'ERGO_DOCKER_CONSOLE_OUTPUT=1',
            'api',
            'bash',
            '-o',
            'pipefail',
            '-c',
            shell,
        ],
    )
    return subprocess.call(cmd, cwd=str(cwd))


def wait_bootstrap_infra(mode: str | None, raw_env: dict[str, str], timeout_sec: float = 180.0) -> bool:
    services = bootstrap_service_names(raw_env)
    pg_user = postgres_container_env(raw_env).get('POSTGRES_USER', 'postgres')
    deadline = time.monotonic() + timeout_sec

    while time.monotonic() < deadline:
        ping_cmd, ping_cwd = build_compose_cmd('exec', mode=mode, extra_args=['-T', 'redis', 'redis-cli', 'ping'])
        ping = subprocess.run(ping_cmd, cwd=str(ping_cwd), capture_output=True, text=True, check=False)
        redis_ok = ping.returncode == 0 and 'PONG' in (ping.stdout or '')

        postgres_ok = True
        if 'postgres' in services:
            pg_cmd, pg_cwd = build_compose_cmd(
                'exec',
                mode=mode,
                extra_args=['-T', 'postgres', 'pg_isready', '-U', pg_user],
            )
            pg = subprocess.run(pg_cmd, cwd=str(pg_cwd), capture_output=True, text=True, check=False)
            postgres_ok = pg.returncode == 0

        if redis_ok and postgres_ok:
            return True
        time.sleep(2)

    print(format_console('error', 'redis/postgres не готовы. Проверьте: ergoms docker-ps'), file=sys.stderr)
    return False


def setup_marker_path(project_root: Path) -> Path:
    return project_root / SETUP_MARKER_REL


def setup_marker_exists(project_root: Path) -> bool:
    return setup_marker_path(project_root).is_file()


def clear_setup_marker(project_root: Path) -> None:
    marker = setup_marker_path(project_root)
    if marker.is_file():
        marker.unlink()


def mark_setup_complete(project_root: Path) -> None:
    marker = setup_marker_path(project_root)
    marker.parent.mkdir(parents=True, exist_ok=True)
    (marker.parent / 'docker').mkdir(parents=True, exist_ok=True)
    marker.touch()
    print(format_console('ok', f'Установка завершена: {SETUP_MARKER_REL.as_posix()}'))


def npm_client_service(mode: str) -> str:
    return 'client' if mode == 'dev' else 'client-build'


def api_install_shell() -> str:
    return (
        'mkdir -p /app/logs/docker '
        '&& cd /app/core/api '
        '&& poetry run python -m commands install 2>&1 | tee -a /app/logs/docker/python-install.log'
    )


def api_migrate_shell() -> str:
    return (
        'mkdir -p /app/logs/docker '
        '&& cd /app/core/api '
        '&& poetry run python -m commands migrate '
        '2>&1 | tee -a /app/logs/docker/migrate.log'
    )


def api_warmup_shell() -> str:
    return (
        'mkdir -p /app/logs/docker '
        '&& cd /app/core/api '
        '&& poetry run python -m commands warmup_caches '
        '2>&1 | tee -a /app/logs/docker/warmup.log'
    )


def remove_compose_artifacts(project_root: Path | None = None) -> None:
    root = project_root or PROJECT_ROOT
    for path in COMPOSE_ARTIFACT_PATHS:
        if path.is_file():
            path.unlink()
            print(format_console('ok', f'Удалён {path.relative_to(root)}'))
