"""
Запуск Redis и потоковый вывод логов для VS Code / ergoms start-redis-dev.

При REDIS_ENABLED=true: ergoms start-redis (если ещё не запущен), затем tail redis.log.
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
from ensure_redis_if_enabled import ensure_redis_for_dev  # noqa: E402
from install_redis import is_installed, ping_redis, redis_packages_dir  # noqa: E402
from log_env import log_file_path  # noqa: E402
from nginx_foreground import _configure_stdio_utf8, tail_log_files  # noqa: E402


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

    if ping_redis(PROJECT_ROOT):
        print(format_console('info', 'Redis уже запущен.'))
    else:
        code = ensure_redis_for_dev()
        if code != 0:
            return code

    return tail_log_files(redis_log_tail_paths(), service='Redis')


if __name__ == '__main__':
    raise SystemExit(main())
