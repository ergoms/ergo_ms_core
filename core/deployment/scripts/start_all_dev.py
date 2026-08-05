"""Запуск сервисов разработки: Redis → API/backend → модули → клиент (аналог Start All Services)."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
PYTHON = sys.executable
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

# Пауза между группами, чтобы Redis успел ответить до API.
_GROUP_DELAY_SEC = 0.8


def _run_warmup() -> int:
    warmup = PROJECT_ROOT / 'core' / 'api' / 'scripts' / 'warmup_caches_if_needed.py'
    return subprocess.call([PYTHON, str(warmup)], cwd=str(PROJECT_ROOT))


def _wait_api_ready() -> int:
    wait_script = SCRIPTS_DIR / 'wait_api_ready.py'
    return subprocess.call([PYTHON, str(wait_script)], cwd=str(PROJECT_ROOT))


def _module_start_commands() -> list[tuple[str, str]]:
    from module_tasks_loader import INCLUDE_START_ALL, tasks_for_target

    commands: list[tuple[str, str]] = []
    for entry in tasks_for_target(PROJECT_ROOT, INCLUDE_START_ALL):
        commands.append((entry.label, entry.command))
    return commands


def _ordered_dev_commands() -> list[tuple[str, str]]:
    """Порядок: DB logs → Redis → API / media / celery → модули → client|nginx."""
    from deployment_env import is_nginx_enabled, is_redis_enabled
    from start_db_logs_dev import db_service_label

    commands: list[tuple[str, str]] = [
        (db_service_label(), 'ergoms start-db-dev'),
    ]
    if is_redis_enabled():
        commands.append(('Redis', 'ergoms start-redis-dev'))
    commands.extend([
        ('API', 'ergoms dev'),
        ('Media API', 'ergoms start-media'),
        ('Worker', 'ergoms start-worker'),
        ('Beat', 'ergoms start-beat'),
    ])
    commands.extend(_module_start_commands())
    if is_nginx_enabled():
        commands.append(('Nginx', 'ergoms start-nginx-dev'))
    else:
        commands.append(('Client', 'ergoms start-client-dev'))
    return commands


def _spawn_windows() -> int:
    redis_started = False
    api_started = False
    for title, command in _ordered_dev_commands():
        if title == 'API' and redis_started:
            time.sleep(_GROUP_DELAY_SEC)
        if title in ('Client', 'Nginx'):
            if api_started:
                _wait_api_ready()
            else:
                time.sleep(_GROUP_DELAY_SEC)
        # Экранирование кавычек в title для cmd start
        safe_title = title.replace('"', "'")
        subprocess.Popen(
            f'start "{safe_title}" cmd /c "{command}"',
            shell=True,
            cwd=str(PROJECT_ROOT),
        )
        if title == 'Redis':
            redis_started = True
            time.sleep(_GROUP_DELAY_SEC)
        if title == 'API':
            api_started = True
    return 0


def _spawn_linux() -> int:
    commands = _ordered_dev_commands()
    processes = []
    redis_started = False
    api_started = False
    for title, command in commands:
        if title == 'API' and redis_started:
            time.sleep(_GROUP_DELAY_SEC)
        if title in ('Client', 'Nginx'):
            if api_started:
                _wait_api_ready()
            else:
                time.sleep(_GROUP_DELAY_SEC)
        processes.append(subprocess.Popen(command, shell=True, cwd=str(PROJECT_ROOT)))
        if title == 'Redis':
            redis_started = True
            time.sleep(_GROUP_DELAY_SEC)
        if title == 'API':
            api_started = True
    exit_code = 0
    for process in processes:
        code = process.wait()
        if code != 0:
            exit_code = code
    return exit_code


def main() -> int:
    code = _run_warmup()
    if code != 0:
        return code
    if os.name == 'nt':
        return _spawn_windows()
    return _spawn_linux()


if __name__ == '__main__':
    raise SystemExit(main())
