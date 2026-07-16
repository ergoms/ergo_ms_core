"""Единая точка входа lifecycle pipeline."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_LIFECYCLE_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _LIFECYCLE_DIR.parent
_PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

from lifecycle.context import HostPlatform  # noqa: E402
from lifecycle.host import ops as host_ops  # noqa: E402
from lifecycle.host.privilege import needs_sudo_reexec, reexec_with_sudo  # noqa: E402
from lifecycle.orchestrator import DeploymentOrchestrator  # noqa: E402
from lifecycle.recipes import RECIPE_REGISTRY  # noqa: E402


def detect_project_root() -> Path:
    cwd = Path.cwd().resolve()
    for candidate in (cwd, *cwd.parents):
        if (candidate / 'core' / 'deployment').is_dir():
            return candidate
    return _PROJECT_ROOT.resolve()


def runner_python_argv(project_root: Path, recipe: str) -> list[str]:
    spec = RECIPE_REGISTRY.get(recipe)
    if spec and recipe == 'setup-full' and not host_ops.venv_exists(project_root, HostPlatform.current()):
        return [*host_ops.system_python_argv(HostPlatform.current()), str(_LIFECYCLE_DIR / 'runner.py')]
    if host_ops.venv_exists(project_root, HostPlatform.current()):
        py = host_ops.venv_python_exe(project_root, HostPlatform.current())
        return [str(py), str(_LIFECYCLE_DIR / 'runner.py')]
    return [*host_ops.system_python_argv(HostPlatform.current()), str(_LIFECYCLE_DIR / 'runner.py')]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description='ErgoMS lifecycle runner')
    parser.add_argument('recipe', nargs='?', help='Имя рецепта pipeline')
    parser.add_argument('--list', action='store_true', help='Список рецептов')
    parser.add_argument('--recreate-venv', action='store_true')
    parser.add_argument('--docker-mode', choices=('dev', 'prod'), default=None)
    parser.add_argument('--purge', action='store_true')
    parser.add_argument('--worker', default='')
    parser.add_argument('--server-name', default='')
    parser.add_argument('--listen-port', default='')
    parser.add_argument('--domain', default='')
    parser.add_argument('--email', default='')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--mode', choices=('dev', 'prod'), default=None, help='alias для --docker-mode')
    return parser


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8')

    parser = build_parser()
    args, extra = parser.parse_known_args(argv)

    if args.list:
        for name in sorted(RECIPE_REGISTRY):
            spec = RECIPE_REGISTRY[name]
            print(f'{name}\t{spec.target}\t{spec.description}')
        return 0

    if not args.recipe:
        parser.print_help()
        return 1

    project_root = detect_project_root()
    spec = RECIPE_REGISTRY.get(args.recipe)
    if spec is None:
        print(format_console('error', f'Неизвестный рецепт: {args.recipe}'), file=sys.stderr)
        return 1

    docker_mode = args.docker_mode or args.mode
    options: dict = {}
    if args.recreate_venv:
        options['recreate_venv'] = True
    if args.purge:
        options['purge'] = True
    if args.worker:
        options['worker'] = args.worker
    if args.server_name:
        options['server_name'] = args.server_name
    if args.listen_port:
        options['listen_port'] = args.listen_port
    if args.domain:
        options['domain'] = args.domain
    if args.email:
        options['email'] = args.email
    if args.dry_run:
        options['dry_run'] = True
    if extra:
        options['compose_extra_args'] = extra

    if needs_sudo_reexec(spec.needs_sudo):
        py_argv = runner_python_argv(project_root, args.recipe)
        sudo_argv = [*py_argv, args.recipe]
        if args.recreate_venv:
            sudo_argv.append('--recreate-venv')
        if args.purge:
            sudo_argv.append('--purge')
        if docker_mode:
            sudo_argv.extend(['--docker-mode', docker_mode])
        sudo_argv.extend(extra)
        return reexec_with_sudo(sudo_argv, cwd=project_root)

    orchestrator = DeploymentOrchestrator(project_root)
    return orchestrator.run_recipe(
        args.recipe,
        runtime=spec.runtime,  # type: ignore[arg-type]
        docker_mode=docker_mode,
        options=options,
        extra_services=extra if args.recipe in ('docker-up', 'docker-init') else None,
    )


if __name__ == '__main__':
    raise SystemExit(main())
