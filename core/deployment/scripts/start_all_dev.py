"""Параллельный запуск сервисов разработки (аналог ergoms start-all / Start All Services)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
PYTHON = sys.executable
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def _run_warmup() -> int:
    warmup = PROJECT_ROOT / 'core' / 'api' / 'scripts' / 'warmup_caches_if_needed.py'
    return subprocess.call([PYTHON, str(warmup)], cwd=str(PROJECT_ROOT))


def _optional_dev_commands() -> list[tuple[str, str]]:
    from deployment_env import is_nginx_enabled, is_redis_enabled

    commands: list[tuple[str, str]] = []
    if is_nginx_enabled():
        commands.append(('Nginx', 'ergoms start-nginx-dev'))
    else:
        commands.append(('Client', 'ergoms start-client-dev'))
    if is_redis_enabled():
        commands.append(('Redis', 'ergoms start-redis-dev'))
    return commands


def _spawn_windows() -> int:
    services = [(title, command) for title, command in _optional_dev_commands()]
    services.extend([
        ('API', 'ergoms dev'),
        ('Media API', 'ergoms start-media'),
        ('Worker', 'ergoms start-worker'),
        ('Beat', 'ergoms start-beat'),
    ])
    for title, command in services:
        subprocess.Popen(
            f'start "{title}" cmd /c "{command}"',
            shell=True,
            cwd=str(PROJECT_ROOT),
        )
    return 0


def _spawn_linux() -> int:
    commands = [command for _, command in _optional_dev_commands()]
    commands.extend([
        'ergoms dev',
        'ergoms start-media',
        'ergoms start-worker',
        'ergoms start-beat',
    ])
    processes = [
        subprocess.Popen(command, shell=True, cwd=str(PROJECT_ROOT))
        for command in commands
    ]
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
