"""
Обёртка ergoms docker * — Docker Compose для ERGO MS.

Тонкий CLI: операции compose — lifecycle.docker.ops, init/bootstrap — DeploymentOrchestrator.
"""

from __future__ import annotations

import argparse
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

from lifecycle.docker import ops as docker_ops  # noqa: E402
from lifecycle.orchestrator import DeploymentOrchestrator  # noqa: E402

# Обратная совместимость для внешних импортов
COMPOSE_ARTIFACT_PATHS = docker_ops.COMPOSE_ARTIFACT_PATHS
SETUP_MARKER_REL = docker_ops.SETUP_MARKER_REL
DOCKER_PYTHON_INSTALL_LOG = docker_ops.DOCKER_PYTHON_INSTALL_LOG
DOCKER_NPM_INSTALL_LOG = docker_ops.DOCKER_NPM_INSTALL_LOG

find_docker_compose = docker_ops.find_docker_compose
compose_file_list = docker_ops.compose_file_list
compose_file_list_full = docker_ops.compose_file_list_full
build_compose_cmd = docker_ops.build_compose_cmd
run_generate_workers = docker_ops.run_generate_workers
render_nginx_docker_config = docker_ops.render_nginx_docker_config
warn_conflicts = docker_ops.warn_conflicts
remove_compose_artifacts = docker_ops.remove_compose_artifacts

from docker_runtime import prepare_compose_artifacts  # noqa: E402


def cmd_up(args: argparse.Namespace) -> int:
    root = PROJECT_ROOT.resolve()
    orchestrator = DeploymentOrchestrator(root)
    return orchestrator.run_recipe(
        'docker-up',
        runtime='docker',
        docker_mode=args.mode,
        extra_services=list(args.extra),
    )


def cmd_down(args: argparse.Namespace) -> int:
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).run_recipe(
        'docker-down',
        runtime='docker',
        docker_mode=args.mode,
        options={'compose_extra_args': list(args.extra)},
    )


def cmd_ps(args: argparse.Namespace) -> int:
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).run_recipe(
        'docker-ps',
        runtime='docker',
        docker_mode=args.mode,
        options={'compose_extra_args': list(args.extra)},
    )


def cmd_logs(args: argparse.Namespace) -> int:
    extra = ['-f'] if args.follow else []
    if args.service:
        extra.append(args.service)
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).run_recipe(
        'docker-logs',
        runtime='docker',
        docker_mode=args.mode,
        options={'compose_extra_args': extra},
    )


def cmd_build(args: argparse.Namespace, *, skip_if_present: bool = False) -> int:
    root = PROJECT_ROOT.resolve()
    orchestrator = DeploymentOrchestrator(root)
    if skip_if_present and docker_ops.should_skip_build(read_env_file(root / '.env')):
        print(format_console('skip', 'Локальные образы уже собраны (DOCKER_BUILD_POLICY=if-missing)'))
        return 0
    extra = list(args.extra or [])
    return orchestrator.run_recipe(
        'docker-build',
        runtime='docker',
        docker_mode=args.mode,
        options={'compose_extra_args': extra},
    )


def cmd_exec_api_shell(_: argparse.Namespace) -> int:
    if not find_docker_compose():
        print(format_console('error', 'Docker не найден.'), file=sys.stderr)
        return 1
    cmd, cwd = build_compose_cmd('exec', extra_args=['api', 'bash'])
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_install_deps(args: argparse.Namespace | None = None) -> int:
    mode = getattr(args, 'mode', None) if args is not None else None
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).docker_install_deps(docker_mode=mode)


def cmd_install_npm_deps(mode: str | None = None) -> int:
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).docker_install_npm(docker_mode=mode)


def cmd_migrate(args: argparse.Namespace | None = None) -> int:
    mode = getattr(args, 'mode', None) if args is not None else None
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).docker_migrate(docker_mode=mode)


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

    root = PROJECT_ROOT.resolve()
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
    remove_compose_artifacts(root)
    docker_ops.clear_setup_marker(root)
    print(format_console('ok', 'Docker-стек ERGO MS полностью удалён. Для нового запуска: ergoms docker-init'))
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    return DeploymentOrchestrator(PROJECT_ROOT.resolve()).docker_init(
        docker_mode=args.mode,
        extra_services=list(args.extra),
        build_extra_args=list(args.extra) if args.extra else [],
    )


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
