"""
Запуск Redis в foreground для VS Code / ergoms start-redis-dev.

При REDIS_ENABLED=true: если Redis уже отвечает (warmup или внешний процесс) — только логи,
без stop/restart (иначе гонка с ergoms dev). Иначе — foreground-запуск portable Redis.
При REDIS_ENABLED=false: выход без сообщений (задача VS Code не занимает терминал).
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from deployment_env import PROJECT_ROOT, is_redis_enabled  # noqa: E402
from install_redis import is_installed, ping_redis, redis_packages_dir  # noqa: E402
from log_env import log_file_path  # noqa: E402
from nginx_foreground import _configure_stdio_utf8, tail_log_files  # noqa: E402
from redis_dev import (  # noqa: E402
    clear_dev_session_marker,
    is_redis_managed_service,
    read_dev_session_marker,
    run_redis_foreground,
)


def redis_log_tail_paths() -> list[Path]:
    candidates = [
        log_file_path('REDIS', PROJECT_ROOT),
        redis_packages_dir(PROJECT_ROOT) / 'logs' / 'redis.log',
    ]
    seen: set[str] = set()
    unique: list[Path] = []
    for path in candidates:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def main() -> int:
    if not is_redis_enabled():
        return 0

    _configure_stdio_utf8()

    if not is_installed(PROJECT_ROOT):
        print(format_console('error', 'Redis не установлен. Выполните: ergoms install-redis'))
        return 1

    if is_redis_managed_service(PROJECT_ROOT):
        print(format_console('info', 'Redis работает как служба ОС; терминал не управляет процессом.'))
        return tail_log_files(redis_log_tail_paths(), service='Redis', process_keeps_running=True)

    marker = read_dev_session_marker(PROJECT_ROOT)

    if ping_redis(PROJECT_ROOT):
        if marker is None:
            hint = 'внешний'
        else:
            hint = marker.get('source', 'warmup')
        print(format_console(
            'info',
            f'Redis уже запущен ({hint}); логи ниже. Ctrl+C только прекращает просмотр.',
        ))
        return tail_log_files(redis_log_tail_paths(), service='Redis', process_keeps_running=True)

    if marker is not None:
        clear_dev_session_marker(PROJECT_ROOT)

    return run_redis_foreground(PROJECT_ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
