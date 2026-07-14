"""
Обёртка ergoms docker * — Docker Compose для ERGO MS.
"""

from __future__ import annotations

import argparse
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
    PROJECT_ROOT as RUNTIME_ROOT,
    compose_profiles,
    docker_mode,
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
    if shutil.which('docker-compose'):
        return ['docker-compose']
    return []


def compose_file_list(mode: str, raw_env: dict[str, str]) -> list[Path]:
    files = [
        DOCKER_DIR / 'docker-compose.yml',
        DOCKER_DIR / f'docker-compose.{mode}.yml',
    ]
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


def run_generate_workers() -> int:
    script = DOCKER_DIR / 'generate_workers_compose.py'
    return subprocess.call([sys.executable, str(script)], cwd=str(DOCKER_DIR))


def build_compose_cmd(
    action: str,
    *,
    mode: str | None = None,
    extra_args: list[str] | None = None,
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
    if not (DOCKER_DIR / 'docker-compose.workers.generated.yml').is_file():
        run_generate_workers()

    if _truthy(raw, 'DOCKER_PROFILE_NGINX'):
        render_nginx_docker_config(raw)

    warn_conflicts(raw)

    cmd = [*compose_bin]
    for compose_file in compose_file_list(docker_mode(raw), raw):
        cmd.extend(['-f', str(compose_file)])

    profiles = compose_profiles(raw)
    for profile in profiles:
        cmd.extend(['--profile', profile])

    cmd.extend(['--env-file', str(DOCKER_DIR / '.compose.env')])
    cmd.append(action)
    if extra_args:
        cmd.extend(extra_args)
    return cmd, DOCKER_DIR


def cmd_up(args: argparse.Namespace) -> int:
    cmd, cwd = build_compose_cmd('up', mode=args.mode, extra_args=['-d'] + args.extra)
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


def cmd_build(args: argparse.Namespace) -> int:
    cmd, cwd = build_compose_cmd('build', mode=args.mode, extra_args=args.extra or [])
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_exec_api_shell(_: argparse.Namespace) -> int:
    compose_bin = find_docker_compose()
    if not compose_bin:
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    cmd, cwd = build_compose_cmd('exec', extra_args=['api', 'bash'])
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_migrate(_: argparse.Namespace) -> int:
    if not find_docker_compose():
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    steps = [
        ['api', 'python', '-m', 'commands', 'makemigrations'],
        ['api', 'python', '-m', 'commands', 'migrate'],
        ['api', 'python', '-m', 'commands', 'warmup_caches'],
    ]
    for step in steps:
        cmd, cwd = build_compose_cmd('exec', extra_args=step)
        code = subprocess.call(cmd, cwd=str(cwd))
        if code != 0:
            return code
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    code = cmd_build(args)
    if code != 0:
        return code
    code = run_generate_workers()
    if code != 0:
        return code
    prepare_compose_artifacts(PROJECT_ROOT)
    code = cmd_up(args)
    if code != 0:
        return code
    print(format_console('info', 'Ожидание готовности API…'))
    import time
    time.sleep(8)
    return cmd_migrate(args)


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

    logs_p = sub.add_parser('logs')
    logs_p.add_argument('service', nargs='?', default='')
    logs_p.add_argument('-f', '--follow', action='store_true')
    logs_p.set_defaults(handler=cmd_logs)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == '__main__':
    raise SystemExit(main())
