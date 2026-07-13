"""Единый каталог и имена файлов логов ERGO MS (без Django)."""

from __future__ import annotations

from pathlib import Path

from deployment_env import PROJECT_ROOT
from log_env import (
    LOG_FILE_DEFAULTS,
    log_basename,
    resolve_logs_dir,
    service_log_map,
)

# Обратная совместимость: константы по умолчанию
LOG_API = LOG_FILE_DEFAULTS['API']
LOG_MEDIA_API = LOG_FILE_DEFAULTS['MEDIA_API']
LOG_CELERY = LOG_FILE_DEFAULTS['CELERY']
LOG_CELERY_WORKER = LOG_FILE_DEFAULTS['CELERY_WORKER']
LOG_CELERY_BEAT = LOG_FILE_DEFAULTS['CELERY_BEAT']
LOG_CELERY_TASKS = LOG_FILE_DEFAULTS['CELERY_TASKS']
LOG_CELERY_BROKER = LOG_FILE_DEFAULTS['CELERY_BROKER']
LOG_NGINX_ACCESS = LOG_FILE_DEFAULTS['NGINX_ACCESS']
LOG_NGINX_ERROR = LOG_FILE_DEFAULTS['NGINX_ERROR']
LOG_REDIS = LOG_FILE_DEFAULTS['REDIS']
LOG_CLIENT_DEV = LOG_FILE_DEFAULTS['CLIENT_DEV']
LOG_CLIENT_BROWSER = LOG_FILE_DEFAULTS['CLIENT_BROWSER']
LOG_AUDIT = LOG_FILE_DEFAULTS['AUDIT']


def ensure_logs_dir(project_root: Path | None = None) -> Path:
    logs_dir = resolve_logs_dir(project_root)
    logs_dir.mkdir(parents=True, exist_ok=True)
    return logs_dir


def log_file_path(name: str, project_root: Path | None = None) -> Path:
    return resolve_logs_dir(project_root) / name


def service_stderr_log(service_name: str, project_root: Path | None = None) -> Path:
    safe = service_name.replace('.service', '')
    return log_file_path(f'{safe}.stderr.log', project_root)


def resolve_service_log_files(service_name: str, project_root: Path | None = None) -> list[Path]:
    base = service_name.replace('.service', '')
    logs_dir = resolve_logs_dir(project_root)
    mapping = service_log_map(project_root)

    if base.startswith('ergo-celery-worker-'):
        return [logs_dir / log_basename('CELERY_WORKER', project_root)]

    names = mapping.get(base)
    if names:
        return [logs_dir / name for name in names]

    legacy = logs_dir / f'{base}.log'
    if legacy.is_file():
        return [legacy]
    return [legacy]


def service_log_files_posix(service_name: str, project_root: Path | None = None) -> list[str]:
    return [str(path).replace('\\', '/') for path in resolve_service_log_files(service_name, project_root)]


def celery_tasks_module_pattern(module_name: str) -> str:
    return f'celery.module.{module_name}'


def _cli_main() -> int:
    import sys

    if len(sys.argv) < 2:
        print(resolve_logs_dir(), end='')
        return 0

    command = sys.argv[1]
    if command == 'dir':
        root = Path(sys.argv[2]) if len(sys.argv) >= 3 else PROJECT_ROOT
        print(resolve_logs_dir(root), end='')
        return 0

    if command == 'service' and len(sys.argv) >= 3:
        root = Path(sys.argv[3]) if len(sys.argv) >= 4 else PROJECT_ROOT
        for path in resolve_service_log_files(sys.argv[2], root):
            print(path)
        return 0

    if command == 'stderr' and len(sys.argv) >= 3:
        root = Path(sys.argv[3]) if len(sys.argv) >= 4 else PROJECT_ROOT
        print(service_stderr_log(sys.argv[2], root), end='')
        return 0

    print(f'Неизвестная команда: {command}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(_cli_main())
