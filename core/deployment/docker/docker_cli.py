"""
Обёртка ergoms docker * — Docker Compose для ERGO MS.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

DOCKER_DIR = Path(__file__).resolve().parent
DEPLOYMENT_DIR = DOCKER_DIR.parent
PROJECT_ROOT = DEPLOYMENT_DIR.parent.parent

if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))
if str(DOCKER_DIR) not in sys.path:
    sys.path.insert(0, str(DOCKER_DIR))

from console_tags import format_console  # noqa: E402
from env_resolvers import read_env_file  # noqa: E402

from docker_runtime import (  # noqa: E402
    BUILD_CACHE_OUTPUT,
    compose_profiles,
    docker_mode,
    effective_docker_build_policy,
    postgres_container_env,
    prepare_compose_artifacts,
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
    """Все фрагменты compose — для полной очистки томов dev/prod и всех profiles."""
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


COMPOSE_ARTIFACT_PATHS = (
    DOCKER_DIR / '.compose.env',
    DOCKER_DIR / '.compose.databases.yaml',
    DOCKER_DIR / 'docker-compose.workers.generated.yml',
    DOCKER_DIR / 'docker-compose.build.generated.yml',
    DOCKER_DIR / 'init' / 'postgres' / '02-celery-databases.sql',
    DOCKER_DIR / 'nginx' / 'ergo_ms.conf.rendered',
)

SETUP_MARKER_REL = Path('logs/.ergo-docker-setup-ok')
DOCKER_PYTHON_INSTALL_LOG = 'logs/docker/python-install.log'
DOCKER_NPM_INSTALL_LOG = 'logs/docker/npm-install.log'


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


def _should_skip_build(raw_env: dict[str, str]) -> bool:
    if effective_docker_build_policy(raw_env) != 'if-missing':
        return False
    return all(_docker_image_exists(name) for name in _required_local_images(raw_env))


def _build_subprocess_env(raw_env: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    # BuildKit обязателен для syntax=1.4 и cache mounts в Dockerfile
    env['DOCKER_BUILDKIT'] = '1'
    env['COMPOSE_DOCKER_CLI_BUILD'] = '1'
    return env


def _env_db_container(raw_env: dict[str, str]) -> bool:
    mode = raw_env.get('DOCKER_DATABASE', 'container').strip().lower()
    if mode != 'container':
        return False
    return _truthy(raw_env, 'DOCKER_PROFILE_POSTGRES', default=True)


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
    if not _truthy(raw_env, 'DOCKER_ENABLED'):
        return
    if _truthy(raw_env, 'REDIS_ENABLED') and raw_env.get('REDIS_HOST', '127.0.0.1') not in ('redis', '127.0.0.1', 'localhost'):
        print(format_console('warning', 'REDIS_HOST указывает на хост — в Docker будет переопределён на сервис redis'))
    if _truthy(raw_env, 'NGINX_ENABLED') and not _truthy(raw_env, 'DOCKER_PROFILE_NGINX'):
        print(format_console('warning', 'NGINX_ENABLED=true, но DOCKER_PROFILE_NGINX=false — nginx на хосте и в Docker могут конфликтовать'))


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
) -> tuple[list[str], Path]:
    compose_bin = find_docker_compose()
    if not compose_bin:
        print(format_console('error', 'Docker не найден. Установите Docker Desktop или docker compose CLI.'), file=sys.stderr)
        sys.exit(1)

    root = PROJECT_ROOT.resolve()
    raw = read_env_file(root / '.env')
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


def cmd_up(args: argparse.Namespace) -> int:
    root = PROJECT_ROOT.resolve()
    raw = read_env_file(root / '.env')
    if args.mode:
        raw = dict(raw)
        raw['DOCKER_MODE'] = args.mode
    if _setup_marker_exists(root):
        cmd, cwd = build_compose_cmd('up', mode=args.mode, extra_args=['-d'] + args.extra)
        return subprocess.call(cmd, cwd=str(cwd))
    print(format_console('info', 'Первичная установка: поднимаем только redis, postgres и api…'))
    return _bootstrap_and_up(args)


def _bootstrap_service_names(raw_env: dict[str, str]) -> list[str]:
    """Инфраструктура для установки зависимостей — без api и прочих приложений."""
    services = ['redis']
    if _env_db_container(raw_env):
        services.append('postgres')
    return services


def _run_api_oneoff(shell: str, *, mode: str | None = None) -> int:
    """Одноразовый контейнер api: вывод в терминал и в logs/docker/*.log (tee в shell)."""
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
            'sh',
            '-c',
            shell,
        ],
    )
    return subprocess.call(cmd, cwd=str(cwd))


def _wait_bootstrap_infra(mode: str | None, raw_env: dict[str, str], timeout_sec: float = 180.0) -> bool:
    """Ждёт готовности redis/postgres (healthcheck через exec, без docker compose wait)."""
    import time

    services = _bootstrap_service_names(raw_env)
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


def _setup_marker_path(project_root: Path) -> Path:
    return project_root / SETUP_MARKER_REL


def _setup_marker_exists(project_root: Path) -> bool:
    return _setup_marker_path(project_root).is_file()


def _clear_setup_marker(project_root: Path) -> None:
    marker = _setup_marker_path(project_root)
    if marker.is_file():
        marker.unlink()


def _mark_setup_complete(project_root: Path) -> None:
    marker = _setup_marker_path(project_root)
    marker.parent.mkdir(parents=True, exist_ok=True)
    (marker.parent / 'docker').mkdir(parents=True, exist_ok=True)
    marker.touch()
    print(format_console('ok', f'Установка завершена: {SETUP_MARKER_REL.as_posix()}'))


def _npm_client_service(mode: str) -> str:
    return 'client' if mode == 'dev' else 'client-build'


def cmd_install_npm_deps(mode: str | None = None) -> int:
    """Установка npm-зависимостей (как ergoms npm run install:all) в одноразовом контейнере client."""
    if not find_docker_compose():
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    resolved_mode = mode or docker_mode(read_env_file(PROJECT_ROOT / '.env'))
    service = _npm_client_service(resolved_mode)
    shell = (
        'mkdir -p /app/logs/docker '
        '&& DOCKER_NPM_INSTALL=always /usr/local/bin/ergo-ensure-npm-deps.sh '
        '2>&1 | tee -a /app/logs/docker/npm-install.log'
    )
    print(format_console('info', f'Установка npm-зависимостей ({service})…'))
    print(format_console('info', f'Журнал: {DOCKER_NPM_INSTALL_LOG}'))
    cmd, cwd = build_compose_cmd(
        'run',
        mode=resolved_mode,
        extra_args=['--rm', '--no-deps', '-T', service, 'sh', '-c', shell],
    )
    return subprocess.call(cmd, cwd=str(cwd))


def _bootstrap_and_up(args: argparse.Namespace) -> int:
    root = PROJECT_ROOT.resolve()
    raw = read_env_file(root / '.env')
    if args.mode:
        raw = dict(raw)
        raw['DOCKER_MODE'] = args.mode

    print(format_console('info', 'Остановка сервисов до завершения установки…'))
    stop_cmd, cwd = build_compose_cmd('stop', mode=args.mode, extra_args=[])
    subprocess.call(stop_cmd, cwd=str(cwd))

    bootstrap = _bootstrap_service_names(raw)
    cmd, cwd = build_compose_cmd('up', mode=args.mode, extra_args=['-d', *bootstrap, *args.extra])
    code = subprocess.call(cmd, cwd=str(cwd))
    if code != 0:
        return code

    print(format_console('info', 'Ожидание redis и postgres…'))
    if not _wait_bootstrap_infra(args.mode, raw):
        return 1

    code = cmd_install_deps(args)
    if code != 0:
        return code

    code = cmd_install_npm_deps(args.mode)
    if code != 0:
        return code

    code = cmd_migrate(args)
    if code != 0:
        return code

    _mark_setup_complete(root)

    print(format_console('info', 'Запуск сервисов приложения…'))
    cmd, cwd = build_compose_cmd('up', mode=args.mode, extra_args=['-d', *args.extra])
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_down(args: argparse.Namespace) -> int:
    cmd, cwd = build_compose_cmd('down', mode=args.mode, extra_args=args.extra)
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_ps(args: argparse.Namespace) -> int:
    cmd, cwd = build_compose_cmd('ps', mode=args.mode, extra_args=args.extra)
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_logs(args: argparse.Namespace) -> int:
    extra = ['-f'] if args.follow else []
    if args.service:
        extra.append(args.service)
    cmd, cwd = build_compose_cmd('logs', mode=args.mode, extra_args=extra)
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_build(args: argparse.Namespace, *, skip_if_present: bool = False) -> int:
    root = PROJECT_ROOT.resolve()
    raw = read_env_file(root / '.env')
    if skip_if_present and _should_skip_build(raw):
        print(format_console('skip', 'Локальные образы уже собраны (DOCKER_BUILD_POLICY=if-missing)'))
        return 0
    cmd, cwd = build_compose_cmd('build', mode=args.mode, extra_args=args.extra or [])
    return subprocess.call(cmd, cwd=str(cwd), env=_build_subprocess_env(raw))


def cmd_exec_api_shell(_: argparse.Namespace) -> int:
    compose_bin = find_docker_compose()
    if not compose_bin:
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    cmd, cwd = build_compose_cmd('exec', extra_args=['api', 'bash'])
    return subprocess.call(cmd, cwd=str(cwd))


def _api_poetry_command(django_command: str) -> list[str]:
    """Django-команды через poetry (как ergoms api …) внутри контейнера api."""
    shell = f'cd /app/core/api && poetry run python -m commands {django_command}'
    return ['api', 'sh', '-c', shell]


def _api_install_shell() -> str:
    return (
        'mkdir -p /app/logs/docker '
        '&& cd /app/core/api '
        '&& poetry run python -m commands install 2>&1 | tee -a /app/logs/docker/python-install.log'
    )


def _api_migrate_shell() -> str:
    return (
        'mkdir -p /app/logs/docker '
        '&& cd /app/core/api '
        '&& (poetry run python -m commands migrate '
        '&& poetry run python -m commands warmup_caches) '
        '2>&1 | tee -a /app/logs/docker/migrate.log'
    )


def cmd_install_deps(args: argparse.Namespace | None = None) -> int:
    """Установка Python-зависимостей ядра и модулей (как ergoms python-install)."""
    if not find_docker_compose():
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    mode = getattr(args, 'mode', None) if args is not None else None
    print(format_console('info', 'Установка Python-зависимостей (ядро + модули)…'))
    print(format_console(
        'info',
        'Прогресс — в этом терминале и в '
        f'{DOCKER_PYTHON_INSTALL_LOG}',
    ))
    code = _run_api_oneoff(_api_install_shell(), mode=mode)
    if code != 0:
        print(format_console('error', f'Установка Python прервалась. Журнал: {DOCKER_PYTHON_INSTALL_LOG}'), file=sys.stderr)
        print(format_console('info', 'Повторите: ergoms docker-init — pip продолжит с уже скачанных пакетов.'), file=sys.stderr)
    return code


def cmd_migrate(args: argparse.Namespace | None = None) -> int:
    if not find_docker_compose():
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    mode = getattr(args, 'mode', None) if args is not None else None
    print(format_console('info', 'Миграции и прогрев кэшей…'))
    return _run_api_oneoff(_api_migrate_shell(), mode=mode)


def _wait_api_container(timeout_sec: float = 120.0) -> bool:
    """Ждёт, пока контейнер api перестанет перезапускаться."""
    import time

    if not find_docker_compose():
        return False
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        cmd, cwd = build_compose_cmd('exec', extra_args=['-T', 'api', 'true'])
        result = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, check=False)
        if result.returncode == 0:
            return True
        time.sleep(3)
    return False


def remove_compose_artifacts() -> None:
    for path in COMPOSE_ARTIFACT_PATHS:
        if path.is_file():
            path.unlink()
            print(format_console('ok', f'Удалён {path.relative_to(PROJECT_ROOT)}'))


_CLEAN_CONFIRM_TEXT = (
    'Полная очистка удалит контейнеры, тома (включая PostgreSQL), локальные образы '
    'и сгенерированные файлы compose.'
)


def _confirm_docker_clean(*, assume_yes: bool) -> bool:
    if assume_yes:
        return True

    print(format_console('warning', _CLEAN_CONFIRM_TEXT))

    if not sys.stdin.isatty():
        print(
            format_console(
                'error',
                'Интерактивное подтверждение недоступно. Повторите с --yes.',
            ),
            file=sys.stderr,
        )
        return False

    try:
        answer = input('Продолжить? (y/N): ').strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        print(format_console('info', 'Очистка отменена.'))
        return False

    if answer in ('y', 'yes'):
        return True

    print(format_console('info', 'Очистка отменена.'))
    return False


def cmd_clean(args: argparse.Namespace) -> int:
    if not _confirm_docker_clean(assume_yes=args.yes):
        return 1

    if not find_docker_compose():
        print(format_console('error', 'Docker не найден. Установите Docker Desktop или docker compose CLI.'), file=sys.stderr)
        return 1

    print(format_console('info', 'Остановка стека и удаление контейнеров, томов и локальных образов…'))
    cmd, cwd = build_compose_cmd(
        'down',
        extra_args=['--remove-orphans', '-v', '--rmi', 'local'],
        for_clean=True,
    )
    code = subprocess.call(cmd, cwd=str(cwd))
    if code != 0:
        print(format_console('warning', f'docker compose down завершился с кодом {code} — продолжаем очистку артефактов'))

    print(format_console('info', 'Удаление сгенерированных файлов compose…'))
    remove_compose_artifacts()
    _clear_setup_marker(PROJECT_ROOT.resolve())
    print(format_console('ok', 'Docker-стек ERGO MS полностью удалён. Для нового запуска: ergoms docker-init'))
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    root = PROJECT_ROOT.resolve()
    _clear_setup_marker(root)
    code = cmd_build(args, skip_if_present=True)
    if code != 0:
        return code
    code = run_generate_workers()
    if code != 0:
        return code
    prepare_compose_artifacts(root)
    return _bootstrap_and_up(args)


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser(description='ErgoMS Docker CLI')
    parser.add_argument('--mode', choices=('dev', 'prod'), default=None)
    sub = parser.add_subparsers(dest='command', required=True)

    for name, handler in (
        ('up', cmd_up),
        ('down', cmd_down),
        ('ps', cmd_ps),
        ('build', cmd_build),
        ('init', cmd_init),
        ('migrate', cmd_migrate),
        ('gen-workers', lambda a: run_generate_workers()),
        ('shell-api', cmd_exec_api_shell),
    ):
        p = sub.add_parser(name)
        p.set_defaults(handler=handler)
        if name in ('up', 'down', 'ps', 'build', 'init'):
            p.add_argument('extra', nargs='*', default=[])

    clean_p = sub.add_parser('clean')
    clean_p.add_argument(
        '--yes',
        action='store_true',
        help='пропустить интерактивное подтверждение (для скриптов и неинтерактивного запуска)',
    )
    clean_p.set_defaults(handler=cmd_clean)

    logs_p = sub.add_parser('logs')
    logs_p.add_argument('service', nargs='?', default='')
    logs_p.add_argument('-f', '--follow', action='store_true')
    logs_p.set_defaults(handler=cmd_logs)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == '__main__':
    raise SystemExit(main())
