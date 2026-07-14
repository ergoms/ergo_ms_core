"""
Запуск Redis для разработки без tail логов.

Используется перед прогревом кэшей и API, когда REDIS_ENABLED=true.
Терминал с логами — ergoms start-redis-dev (VS Code Optional Services).
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from deployment_env import PROJECT_ROOT, is_redis_enabled  # noqa: E402
from install_redis import is_installed, ping_redis  # noqa: E402
from log_env import log_file_path  # noqa: E402
from nginx_foreground import _configure_stdio_utf8  # noqa: E402


def ensure_redis_for_dev(*, quiet: bool = False) -> int:
    """
    Запускает Redis, если REDIS_ENABLED=true и процесс ещё не отвечает на ping.

    При REDIS_ENABLED=false возвращает 0 без действий.
    """
    if not is_redis_enabled():
        return 0

    if not is_installed(PROJECT_ROOT):
        print(format_console('error', 'Redis не установлен. Выполните: ergoms install-redis'))
        return 1

    if ping_redis(PROJECT_ROOT):
        if not quiet:
            print(format_console('info', 'Redis уже запущен.'))
        return 0

    result = subprocess.run(
        'ergoms start-redis',
        shell=True,
        cwd=str(PROJECT_ROOT),
        check=False,
    )
    if result.returncode != 0:
        return result.returncode

    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline:
        if ping_redis(PROJECT_ROOT):
            if not quiet:
                print(format_console('ok', 'Redis запущен.'))
            return 0
        time.sleep(0.5)

    log_hint = log_file_path('REDIS', PROJECT_ROOT)
    print(format_console('error', f'Redis не ответил на ping. Проверьте лог: {log_hint}'))
    return 1


def main() -> int:
    if not is_redis_enabled():
        return 0

    _configure_stdio_utf8()
    return ensure_redis_for_dev()


if __name__ == '__main__':
    raise SystemExit(main())
